# flutter_webrtc calls into libwebrtc's Java classes through JNI; R8 can't see those uses.
-keep class org.webrtc.** { *; }
-keep class com.cloudwebrtc.webrtc.** { *; }
