#include <jni.h>
#include <dlfcn.h>
#include <string>
#include <vector>
#include <mutex>
#include <cstdint>
#include <cstring>

static JavaVM* vm;
static constexpr bool validRequestSize(size_t size, bool source) {
    return size <= (source ? 12u : 5u) * 1024 * 1024;
}
static_assert(validRequestSize(6u * 1024 * 1024, true));
static_assert(validRequestSize(12u * 1024 * 1024, true));
static_assert(!validRequestSize(12u * 1024 * 1024 + 1, true));
static_assert(!validRequestSize(6u * 1024 * 1024, false));
static void* core;
static void* mpv;
static std::once_flag libraries;
static bool loaded;
static void fail(JNIEnv* env, const char* message) {
    env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), message);
}
static bool load(JNIEnv* env) {
    std::call_once(libraries, [] {
        core = dlopen("libduanju_core.so", RTLD_NOW | RTLD_LOCAL);
        mpv = dlopen("libmpv.so", RTLD_NOW | RTLD_GLOBAL);
        if (!core || !mpv) return;
        auto setVm = reinterpret_cast<int (*)(void*)>(dlsym(mpv, "mpv_lavc_set_java_vm"));
        if (!setVm || setVm(vm) < 0) return;
        loaded = dlsym(core, "DuanjuRequest") && dlsym(core, "DuanjuFree") &&
            dlsym(core, "RealDramaSourceRequest") && dlsym(mpv, "mpv_create");
    });
    if (!loaded) fail(env, "Native playback libraries unavailable");
    return loaded;
}
template<typename T> static T symbol(const char* name) { return reinterpret_cast<T>(dlsym(mpv, name)); }
static std::string utf8(JNIEnv* env, jbyteArray data) {
    if (!data) return {};
    std::string result(env->GetArrayLength(data), '\0');
    env->GetByteArrayRegion(data, 0, result.size(), reinterpret_cast<jbyte*>(result.data()));
    return result;
}
static jbyteArray bytes(JNIEnv* env, const char* data) {
    auto size = data ? strlen(data) : 0;
    auto result = env->NewByteArray(size);
    if (size) env->SetByteArrayRegion(result, 0, size, reinterpret_cast<const jbyte*>(data));
    return result;
}
extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* value, void*) { vm = value; return JNI_VERSION_1_6; }
extern "C" JNIEXPORT jbyteArray JNICALL Java_com_real_drama_compose_NativeBridge_request(JNIEnv* env, jobject, jbyteArray input, jboolean source) {
    if (!load(env)) return nullptr;
    if (!input || !validRequestSize(env->GetArrayLength(input), source)) { fail(env, "Native request exceeds size limit"); return nullptr; }
    auto data = utf8(env, input);
    if (data.find('\0') != std::string::npos) { fail(env, "Invalid native request encoding"); return nullptr; }
    auto call = reinterpret_cast<char* (*)(const char*)>(dlsym(core, source ? "RealDramaSourceRequest" : "DuanjuRequest"));
    auto release = reinterpret_cast<void (*)(void*)>(dlsym(core, "DuanjuFree"));
    auto output = call(data.c_str());
    auto result = bytes(env, output);
    release(output);
    return result;
}
struct Player { void* handle; jobject surface; };
extern "C" JNIEXPORT jlong JNICALL Java_com_real_drama_compose_NativeBridge_createPlayer(JNIEnv* env, jobject, jobject surface, jboolean hardware, jboolean lowMemory) {
    if (!load(env)) return 0;
    auto handle = symbol<void* (*)()>("mpv_create")();
    if (!handle) { fail(env, "Player allocation failed"); return 0; }
    auto p = new Player{handle, env->NewGlobalRef(surface)};
    auto option = symbol<int (*)(void*, const char*, const char*)>("mpv_set_option_string");
    option(handle, "config", "no"); option(handle, "terminal", "no");
    option(handle, "vo", "gpu"); option(handle, "gpu-context", "android");
    option(handle, "opengl-es", "yes"); option(handle, "force-window", "yes");
    option(handle, "hwdec", hardware ? "auto-safe" : "no");
    option(handle, "ao", "opensles"); option(handle, "idle", "yes");
    option(handle, "keep-open", "yes"); option(handle, "input-default-bindings", "no");
    option(handle, "cache", "yes"); option(handle, "demuxer-max-bytes", lowMemory ? "2097152" : "33554432");
    option(handle, "demuxer-max-back-bytes", lowMemory ? "0" : "8388608");
    int64_t window = reinterpret_cast<int64_t>(p->surface);
    auto set = symbol<int (*)(void*, const char*, int, void*)>("mpv_set_option");
    set(handle, "wid", 4, &window);
    if (symbol<int (*)(void*)>("mpv_initialize")(handle) < 0) {
        symbol<void (*)(void*)>("mpv_terminate_destroy")(handle);
        env->DeleteGlobalRef(p->surface); delete p; fail(env, "Player initialization failed"); return 0;
    }
    return reinterpret_cast<jlong>(p);
}
struct MpvEvent { int event_id; int error; uint64_t reply_userdata; void* data; };
struct MpvEnd { int reason; int error; };
static int playerError(Player* p) {
    if (!p) return 0;
    for (int i = 0; i < 32; i++) {
        auto event = symbol<MpvEvent* (*)(void*, double)>("mpv_wait_event")(p->handle, 0);
        if (!event || event->event_id == 0) break;
        if (event->event_id == 7 && event->data) {
            auto end = static_cast<MpvEnd*>(event->data);
            if (end->error < 0) return end->error;
        }
    }
    return 0;
}
extern "C" JNIEXPORT jdoubleArray JNICALL Java_com_real_drama_compose_NativeBridge_playerSnapshot(JNIEnv* env, jobject, jlong address) {
    auto p = reinterpret_cast<Player*>(address);
    double values[11] = {0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0};
    if (p) {
        static auto get = symbol<int (*)(void*, const char*, int, void*)>("mpv_get_property");
        if (!get) { fail(env, "Player properties unavailable"); return nullptr; }
        const char* numbers[] = {"time-pos", "duration", "dwidth", "dheight", "demuxer-cache-time"};
        for (int i = 0; i < 5; i++) {
            double number = 0;
            if (get(p->handle, numbers[i], 5, &number) >= 0) values[i] = number;
        }
        const char* flags[] = {"pause", "eof-reached", "paused-for-cache", "core-idle"};
        for (int i = 0; i < 4; i++) {
            int flag = 0;
            if (get(p->handle, flags[i], 3, &flag) >= 0) values[i + 5] = flag;
        }
        values[9] = playerError(p);
        int64_t rotation = 0;
        if (get(p->handle, "video-out-params/rotate", 4, &rotation) >= 0) values[10] = rotation;
    }
    auto result = env->NewDoubleArray(11);
    if (result) env->SetDoubleArrayRegion(result, 0, 11, values);
    return result;
}
extern "C" JNIEXPORT jint JNICALL Java_com_real_drama_compose_NativeBridge_playerCommand(JNIEnv* env, jobject, jlong address, jobjectArray args) {
    auto p = reinterpret_cast<Player*>(address);
    if (!p) return -1;
    std::vector<std::string> values;
    auto count = env->GetArrayLength(args);
    for (int i = 0; i < count; i++) {
        auto value = reinterpret_cast<jbyteArray>(env->GetObjectArrayElement(args, i));
        values.push_back(utf8(env, value)); env->DeleteLocalRef(value);
    }
    std::vector<const char*> command;
    for (auto& value : values) command.push_back(value.c_str());
    command.push_back(nullptr);
    return symbol<int (*)(void*, const char**)>("mpv_command")(p->handle, command.data());
}
extern "C" JNIEXPORT jbyteArray JNICALL Java_com_real_drama_compose_NativeBridge_playerGet(JNIEnv* env, jobject, jlong address, jbyteArray name) {
    auto p = reinterpret_cast<Player*>(address);
    if (!p) return bytes(env, "");
    auto property = utf8(env, name);
    auto output = symbol<char* (*)(void*, const char*)>("mpv_get_property_string")(p->handle, property.c_str());
    auto result = bytes(env, output);
    symbol<void (*)(void*)>("mpv_free")(output);
    return result;
}
extern "C" JNIEXPORT void JNICALL Java_com_real_drama_compose_NativeBridge_destroyPlayer(JNIEnv* env, jobject, jlong address) {
    auto p = reinterpret_cast<Player*>(address);
    if (!p) return;
    symbol<void (*)(void*)>("mpv_terminate_destroy")(p->handle);
    env->DeleteGlobalRef(p->surface); delete p;
}
