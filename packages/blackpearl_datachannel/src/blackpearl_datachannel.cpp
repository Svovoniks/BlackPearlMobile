// The few calls the Dart side makes into libdatachannel, and its callbacks passed on to Dart.
//
// libdatachannel calls back on its own threads with buffers it frees as soon as the callback returns. Dart's listener
// callbacks (NativeCallable.listener) run later, on the isolate's own thread, so every callback here copies what it was
// given into memory the Dart side frees with bp_dc_free once it has read it. Events for one peer connection or channel
// come from one libdatachannel thread at a time, in order.

#include <rtc/rtc.h>

#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstring>

#ifdef __ANDROID__
#include <android/log.h>
#endif

#if defined(_WIN32)
#define BP_EXPORT extern "C" __declspec(dllexport)
#else
#define BP_EXPORT extern "C" __attribute__((visibility("default")))
#endif

namespace {

// What happened, as the Dart side's _Event knows it (lib/blackpearl_datachannel.dart).
enum Event : int32_t {
	kDescription = 1, // peer; data: SDP, extra: type
	kCandidate = 2,   // peer; data: candidate line, extra: media id
	kState = 3,       // peer; value: rtcState
	kGathering = 4,   // peer; value: rtcGatheringState
	kChannel = 5,     // peer; value: the new channel's id, data: its label (a channel the other side opened)
	kOpen = 6,        // channel
	kClosed = 7,      // channel
	kError = 8,       // channel; data: message
	kText = 9,        // channel; data: UTF-8 text
	kBinary = 10,     // channel; data: bytes
	kLog = 11,        // value: rtcLogLevel, data: message
};

using Listener = void (*)(int32_t event, int32_t id, int32_t value, uint8_t *data, int32_t size, uint8_t *extra,
                          int32_t extraSize);

std::atomic<Listener> listener{nullptr};

uint8_t *copy(const void *data, size_t size) {
	// One byte more, always zero, so text can be read as a C string too.
	auto *out = static_cast<uint8_t *>(std::malloc(size + 1));
	if (!out)
		return nullptr;
	if (size)
		std::memcpy(out, data, size);
	out[size] = 0;
	return out;
}

void emit(Event event, int id, int value, const void *data = nullptr, size_t size = 0, const void *extra = nullptr,
          size_t extraSize = 0) {
	Listener to = listener.load();
	if (!to)
		return;
	uint8_t *dataCopy = data ? copy(data, size) : nullptr;
	uint8_t *extraCopy = extra ? copy(extra, extraSize) : nullptr;
	to(event, id, value, dataCopy, int32_t(size), extraCopy, int32_t(extraSize));
}

void emitText(Event event, int id, int value, const char *text, const char *extra = nullptr) {
	emit(event, id, value, text, text ? std::strlen(text) : 0, extra, extra ? std::strlen(extra) : 0);
}

void RTC_API onDescription(int pc, const char *sdp, const char *type, void *) {
	emitText(kDescription, pc, 0, sdp, type);
}

void RTC_API onCandidate(int pc, const char *candidate, const char *mid, void *) {
	emitText(kCandidate, pc, 0, candidate, mid);
}

void RTC_API onState(int pc, rtcState state, void *) { emit(kState, pc, int(state)); }

void RTC_API onGathering(int pc, rtcGatheringState state, void *) { emit(kGathering, pc, int(state)); }

void RTC_API onOpen(int id, void *) { emit(kOpen, id, 0); }

void RTC_API onClosed(int id, void *) { emit(kClosed, id, 0); }

void RTC_API onError(int id, const char *error, void *) { emitText(kError, id, 0, error); }

void RTC_API onMessage(int id, const char *message, int size, void *) {
	// A negative size is text: its length, NUL included, negated.
	if (size < 0)
		emit(kText, id, 0, message, size_t(-size - 1));
	else
		emit(kBinary, id, 0, message, size_t(size));
}

void watchChannel(int dc) {
	rtcSetOpenCallback(dc, onOpen);
	rtcSetClosedCallback(dc, onClosed);
	rtcSetErrorCallback(dc, onError);
	rtcSetMessageCallback(dc, onMessage);
}

void RTC_API onChannel(int pc, int dc, void *) {
	// Before anything can arrive on it: the channel's callbacks are set before this one returns.
	watchChannel(dc);
	char label[256] = {0};
	if (rtcGetDataChannelLabel(dc, label, sizeof(label)) < 0)
		label[0] = 0;
	emitText(kChannel, pc, dc, label);
}

std::atomic<bool> logToListener{false};

void RTC_API onLog(rtcLogLevel level, const char *message) {
#ifdef __ANDROID__
	int priority = level <= RTC_LOG_ERROR ? ANDROID_LOG_ERROR : level == RTC_LOG_WARNING ? ANDROID_LOG_WARN : ANDROID_LOG_INFO;
	__android_log_write(priority, "datachannel", message);
#endif
	if (logToListener.load())
		emitText(kLog, 0, int(level), message);
}

} // namespace

/// Where events go from now on: a NativeCallable.listener's function, or null for nowhere.
BP_EXPORT void bp_dc_set_listener(Listener to) { listener.store(to); }

/// Frees what an event carried.
BP_EXPORT void bp_dc_free(void *data) { std::free(data); }

/// Logs libdatachannel's messages at [level] and above (rtcLogLevel): on Android to logcat, and also to the listener
/// when [toListener].
BP_EXPORT void bp_dc_log(int32_t level, int32_t toListener) {
	logToListener.store(toListener != 0);
	rtcInitLogger(rtcLogLevel(level), onLog);
}

/// A new peer connection with [servers] (libdatachannel's URLs: `stun:host:port`, `turn:user:pass@host:port?...`), only
/// through a relay when [relayOnly]. Its local description is made only when asked for (bp_dc_set_local_description).
/// Returns its id, or a negative error.
BP_EXPORT int32_t bp_dc_peer_create(const char **servers, int32_t count, int32_t relayOnly) {
	rtcConfiguration config;
	std::memset(&config, 0, sizeof(config));
	config.iceServers = servers;
	config.iceServersCount = count;
	config.iceTransportPolicy = relayOnly ? RTC_TRANSPORT_POLICY_RELAY : RTC_TRANSPORT_POLICY_ALL;
	config.disableAutoNegotiation = true;
	int pc = rtcCreatePeerConnection(&config);
	if (pc < 0)
		return pc;
	rtcSetLocalDescriptionCallback(pc, onDescription);
	rtcSetLocalCandidateCallback(pc, onCandidate);
	rtcSetStateChangeCallback(pc, onState);
	rtcSetGatheringStateChangeCallback(pc, onGathering);
	rtcSetDataChannelCallback(pc, onChannel);
	return pc;
}

/// Makes the local description of [type] (`offer` or `answer`, or null to pick), which arrives as an event, and starts
/// gathering candidates: the ICE sockets are open once this returns.
BP_EXPORT int32_t bp_dc_set_local_description(int32_t pc, const char *type) { return rtcSetLocalDescription(pc, type); }

BP_EXPORT int32_t bp_dc_set_remote_description(int32_t pc, const char *sdp, const char *type) {
	return rtcSetRemoteDescription(pc, sdp, type);
}

BP_EXPORT int32_t bp_dc_add_remote_candidate(int32_t pc, const char *candidate, const char *mid) {
	return rtcAddRemoteCandidate(pc, candidate, mid);
}

/// The candidates of the pair ICE chose, as candidate lines; a negative error when there is none yet.
BP_EXPORT int32_t bp_dc_selected_pair(int32_t pc, char *local, int32_t localSize, char *remote, int32_t remoteSize) {
	return rtcGetSelectedCandidatePair(pc, local, localSize, remote, remoteSize);
}

/// Closes [pc] and frees it with its channels. Waits for libdatachannel's threads to let go of it, so not on a thread
/// that must stay responsive.
BP_EXPORT int32_t bp_dc_peer_delete(int32_t pc) {
	rtcClosePeerConnection(pc);
	return rtcDeletePeerConnection(pc);
}

/// A reliable, ordered data channel labelled [label] on [pc]. Returns its id, or a negative error.
BP_EXPORT int32_t bp_dc_channel_create(int32_t pc, const char *label) {
	rtcDataChannelInit init;
	std::memset(&init, 0, sizeof(init));
	int dc = rtcCreateDataChannelEx(pc, label, &init);
	if (dc >= 0)
		watchChannel(dc);
	return dc;
}

/// Sends [text] (UTF-8, NUL-terminated) as a text message.
BP_EXPORT int32_t bp_dc_send_text(int32_t dc, const char *text) { return rtcSendMessage(dc, text, -1); }

/// Sends [size] bytes as a binary message.
BP_EXPORT int32_t bp_dc_send_binary(int32_t dc, const uint8_t *data, int32_t size) {
	return rtcSendMessage(dc, reinterpret_cast<const char *>(data), size);
}

BP_EXPORT int32_t bp_dc_channel_close(int32_t dc) { return rtcClose(dc); }
