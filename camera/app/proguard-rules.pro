# Develop Camera's release shrinking (R8).
# The engine's JNI entry points: native-lib.cpp exports Java_com_jegly_developcamera_engine_DevelopEngine_native*,
# so the class keeps its name and its native methods keep theirs.
-keep class com.jegly.developcamera.engine.DevelopEngine {
    native <methods>;
}
