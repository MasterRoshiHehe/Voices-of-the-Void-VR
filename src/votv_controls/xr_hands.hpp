// VOTV VR: OpenXR hand tracking for the finger animation (user 2026-11-27 18:52: "just make it happen").
//
// Virtual Desktop's runtime offers XR_EXT_hand_tracking and XR_EXT_hand_tracking_data_source (UEVR log, run
// 18:45), which give 26 hand joints, also driven by the controllers while they are held. UEVR 1.05 doesn't enable
// them, and extensions can only be enabled when the OpenXR instance is created. This plugin is loaded about 2 s
// before UEVR creates that instance, so on load it redirects xrCreateInstance (UEVRBackend's import slots and the
// loader's export entry) to a wrapper that adds the extensions when the runtime lists them, falling back to the
// original request if the runtime refuses. Afterwards a hand tracker per hand is created on UEVR's session and
// joints are read in UEVR's stage space; per-finger curl (0..1) is computed from the joint chain and fed into the
// existing finger animation. Headers: Khronos OpenXR-SDK 1.0.34 (Apache-2.0), tools/openxr-sdk (not in the repo).
#pragma once
#include <windows.h>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <string>
#include <vector>

#define XR_USE_PLATFORM_WIN32
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <openxr/openxr_loader_negotiation.h>
#include <MinHook.h>   // BSD-2, tools/minhook (not in the repo)

namespace xrh {

inline PFN_xrCreateInstance g_orig_create = nullptr;
inline std::atomic<bool> g_ext_enabled{false};
inline std::atomic<bool> g_hook_installed{false};
inline std::string g_log;   // read by the plugin once and logged
inline HMODULE g_loader = nullptr;
inline PFN_xrGetInstanceProcAddr g_rt_gipa = nullptr;     // the runtime's own (below the loader and layers)
inline PFN_xrCreateInstance g_orig_rt_create = nullptr;

inline bool runtime_has(const char* name) {
    PFN_xrEnumerateInstanceExtensionProperties enumerate = nullptr;
    if (g_rt_gipa) g_rt_gipa(XR_NULL_HANDLE, "xrEnumerateInstanceExtensionProperties", (PFN_xrVoidFunction*)&enumerate);
    if (!enumerate && g_loader) enumerate = (PFN_xrEnumerateInstanceExtensionProperties)GetProcAddress(g_loader, "xrEnumerateInstanceExtensionProperties");
    if (!enumerate) return false;
    uint32_t n = 0;
    if (XR_FAILED(enumerate(nullptr, 0, &n, nullptr)) || n == 0) return false;
    std::vector<XrExtensionProperties> props(n, {XR_TYPE_EXTENSION_PROPERTIES});
    if (XR_FAILED(enumerate(nullptr, n, &n, props.data()))) return false;
    for (auto& p : props) if (std::strcmp(p.extensionName, name) == 0) return true;
    return false;
}

inline XrResult create_with_hands(PFN_xrCreateInstance next, const char* where, const XrInstanceCreateInfo* ci, XrInstance* inst);
inline XrResult XRAPI_CALL hooked_create(const XrInstanceCreateInfo* ci, XrInstance* inst) { return create_with_hands(g_orig_create, "loader", ci, inst); }
inline XrResult XRAPI_CALL hooked_rt_create(const XrInstanceCreateInfo* ci, XrInstance* inst) { return create_with_hands(g_orig_rt_create, "runtime", ci, inst); }
inline XrResult create_with_hands(PFN_xrCreateInstance next, const char* where, const XrInstanceCreateInfo* ci, XrInstance* inst) {
    std::vector<const char*> ext(ci->enabledExtensionNames, ci->enabledExtensionNames + ci->enabledExtensionCount);
    int added = 0;
    for (const char* want : {XR_EXT_HAND_TRACKING_EXTENSION_NAME, XR_EXT_HAND_TRACKING_DATA_SOURCE_EXTENSION_NAME,
                             XR_KHR_WIN32_CONVERT_PERFORMANCE_COUNTER_TIME_EXTENSION_NAME}) {
        bool have = false;
        for (auto e : ext) if (std::strcmp(e, want) == 0) have = true;
        if (!have && runtime_has(want)) { ext.push_back(want); ++added; }
    }
    XrInstanceCreateInfo c = *ci;
    c.enabledExtensionCount = (uint32_t)ext.size();
    c.enabledExtensionNames = ext.data();
    XrResult r = next(&c, inst);
    if (XR_FAILED(r) && added) {
        g_log += std::string(where) + " xrCreateInstance with hand tracking failed (" + std::to_string((int)r) + "), retried without; ";
        return next(ci, inst);
    }
    // enabled if this call added them, or they were already in the list (added by the loader-level wrapper)
    bool present = true;
    for (const char* want : {XR_EXT_HAND_TRACKING_EXTENSION_NAME, XR_KHR_WIN32_CONVERT_PERFORMANCE_COUNTER_TIME_EXTENSION_NAME}) {
        bool have = false; for (auto e : ext) if (std::strcmp(e, want) == 0) have = true; present = present && have; }
    if (XR_SUCCEEDED(r) && present) g_ext_enabled = true;
    g_log += std::string(where) + " xrCreateInstance: added " + std::to_string(added) + " extension(s), result " + std::to_string((int)r) + "; ";
    return r;
}

// Patch every import slot for openxr_loader.dll!name in module m (normal and delay-load tables).
inline int patch_imports(HMODULE m, const char* name, void* fn) {
    auto base = (uint8_t*)m;
    auto dos = (IMAGE_DOS_HEADER*)base;
    auto nt = (IMAGE_NT_HEADERS64*)(base + dos->e_lfanew);
    int patched = 0;
    auto patch_slot = [&](ULONGLONG* slot) {
        DWORD old; VirtualProtect(slot, sizeof(*slot), PAGE_READWRITE, &old);
        *slot = (ULONGLONG)fn; VirtualProtect(slot, sizeof(*slot), old, &old); ++patched;
    };
    auto& imp = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (imp.VirtualAddress) {
        for (auto d = (IMAGE_IMPORT_DESCRIPTOR*)(base + imp.VirtualAddress); d->Name; ++d) {
            if (_stricmp((char*)(base + d->Name), "openxr_loader.dll") != 0) continue;
            auto names = (IMAGE_THUNK_DATA64*)(base + (d->OriginalFirstThunk ? d->OriginalFirstThunk : d->FirstThunk));
            auto iat = (IMAGE_THUNK_DATA64*)(base + d->FirstThunk);
            for (; names->u1.AddressOfData; ++names, ++iat) {
                if (IMAGE_SNAP_BY_ORDINAL64(names->u1.Ordinal)) continue;
                auto ibn = (IMAGE_IMPORT_BY_NAME*)(base + names->u1.AddressOfData);
                if (std::strcmp((char*)ibn->Name, name) == 0) patch_slot(&iat->u1.Function);
            }
        }
    }
    auto& dl = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT];
    if (dl.VirtualAddress) {
        for (auto d = (IMAGE_DELAYLOAD_DESCRIPTOR*)(base + dl.VirtualAddress); d->DllNameRVA; ++d) {
            if (_stricmp((char*)(base + d->DllNameRVA), "openxr_loader.dll") != 0) continue;
            auto names = (IMAGE_THUNK_DATA64*)(base + d->ImportNameTableRVA);
            auto iat = (IMAGE_THUNK_DATA64*)(base + d->ImportAddressTableRVA);
            for (; names->u1.AddressOfData; ++names, ++iat) {
                if (IMAGE_SNAP_BY_ORDINAL64(names->u1.Ordinal)) continue;
                auto ibn = (IMAGE_IMPORT_BY_NAME*)(base + names->u1.AddressOfData);
                if (std::strcmp((char*)ibn->Name, name) == 0) patch_slot(&iat->u1.Function);
            }
        }
    }
    return patched;
}

// Redirect the loader's own export entry (for GetProcAddress users) through a jump stub placed above the module.
inline bool patch_export(HMODULE m, const char* name, void* fn) {
    auto base = (uint8_t*)m;
    auto nt = (IMAGE_NT_HEADERS64*)(base + ((IMAGE_DOS_HEADER*)base)->e_lfanew);
    auto& ed = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
    if (!ed.VirtualAddress) return false;
    auto exp = (IMAGE_EXPORT_DIRECTORY*)(base + ed.VirtualAddress);
    auto names = (DWORD*)(base + exp->AddressOfNames);
    auto ords = (WORD*)(base + exp->AddressOfNameOrdinals);
    auto funcs = (DWORD*)(base + exp->AddressOfFunctions);
    for (DWORD i = 0; i < exp->NumberOfNames; ++i) {
        if (std::strcmp((char*)(base + names[i]), name) != 0) continue;
        uint8_t* stub = nullptr;
        for (uintptr_t a = ((uintptr_t)base + nt->OptionalHeader.SizeOfImage + 0xFFFF) & ~(uintptr_t)0xFFFF;
             a < (uintptr_t)base + 0x7FFF0000ull && !stub; a += 0x10000)
            stub = (uint8_t*)VirtualAlloc((void*)a, 4096, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE);
        if (!stub) return false;
        stub[0] = 0xFF; stub[1] = 0x25; std::memset(stub + 2, 0, 4); std::memcpy(stub + 6, &fn, 8);   // jmp [rip+0]; dq fn
        DWORD* slot = &funcs[ords[i]];
        DWORD old; VirtualProtect(slot, 4, PAGE_READWRITE, &old);
        *slot = (DWORD)(stub - base); VirtualProtect(slot, 4, old, &old);
        return true;
    }
    return false;
}

inline void install() {
    if (g_hook_installed.exchange(true)) return;
    // kill switch, read before anything is patched: ctl_hand_tracking=0 in the profile's scripts/votv_controls.txt
    {
        char* ad = nullptr; size_t n = 0; _dupenv_s(&ad, &n, "APPDATA");
        std::string f = std::string(ad ? ad : "") + "/UnrealVRMod/VotV-Win64-Shipping/scripts/votv_controls.txt";
        free(ad);
        if (FILE* fp = nullptr; fopen_s(&fp, f.c_str(), "rb") == 0 && fp) {
            char buf[8192]{}; size_t r = fread(buf, 1, sizeof(buf) - 1, fp); fclose(fp); buf[r] = 0;
            if (std::strstr(buf, "ctl_hand_tracking=0")) { g_log += "disabled by ctl_hand_tracking=0; "; return; }
        }
    }
    wchar_t path[MAX_PATH]{};
    HMODULE backend = GetModuleHandleW(L"UEVRBackend.dll");
    g_loader = GetModuleHandleW(L"openxr_loader.dll");
    if (!g_loader && backend && GetModuleFileNameW(backend, path, MAX_PATH)) {
        std::wstring p(path); p = p.substr(0, p.find_last_of(L"\\/") + 1) + L"openxr_loader.dll";
        g_loader = LoadLibraryW(p.c_str());
    }
    if (!g_loader) { g_log += "openxr_loader.dll not found; "; return; }
    {
        wchar_t lp[MAX_PATH]{}; GetModuleFileNameW(g_loader, lp, MAX_PATH);
        char buf[MAX_PATH * 2]{}; WideCharToMultiByte(CP_UTF8, 0, lp, -1, buf, sizeof(buf), nullptr, nullptr);
        SYSTEMTIME tm; GetLocalTime(&tm);
        char ts[32]; snprintf(ts, sizeof(ts), "%02d:%02d:%02d.%03d", tm.wHour, tm.wMinute, tm.wSecond, tm.wMilliseconds);
        g_log += std::string("hook installed at ") + ts + " on " + buf + "; ";
    }
    void* target = (void*)GetProcAddress(g_loader, "xrCreateInstance");
    if (!target) { g_log += "xrCreateInstance not exported; "; return; }
    // Run 18:58: patching import/export entries missed UEVR's call (it already held the function pointer), so the
    // function body itself is hooked (MinHook trampoline): every caller goes through the wrapper.
    MH_STATUS st = MH_Initialize();
    if (st != MH_OK && st != MH_ERROR_ALREADY_INITIALIZED) { g_log += "MinHook init failed; "; return; }
    st = MH_CreateHook(target, (void*)&hooked_create, (void**)&g_orig_create);
    if (st == MH_OK) st = MH_EnableHook(target);
    g_log += std::string("loader hook: ") + (st == MH_OK ? "enabled" : ("failed " + std::to_string((int)st))) + "; ";
    (void)backend;
    // Run 19:04: the loader hook was in place 4 s before UEVR created its instance, yet never called (UEVR links
    // the loader statically). So the runtime itself is hooked too: load the active runtime named in the OpenXR
    // registry key, negotiate for its xrGetInstanceProcAddr, and hook the xrCreateInstance it hands out.
    HKEY k; wchar_t json[MAX_PATH]{}; DWORD sz = sizeof(json);
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Khronos\\OpenXR\\1", 0, KEY_READ, &k) == ERROR_SUCCESS) {
        RegQueryValueExW(k, L"ActiveRuntime", nullptr, nullptr, (LPBYTE)json, &sz); RegCloseKey(k);
    }
    std::wstring jp(json);
    if (jp.empty()) { g_log += "no active OpenXR runtime in the registry; "; return; }
    std::string text;
    if (FILE* fp = nullptr; _wfopen_s(&fp, jp.c_str(), L"rb") == 0 && fp) { char b[4096]{}; size_t r = fread(b, 1, sizeof(b) - 1, fp); fclose(fp); text.assign(b, r); }
    auto q = text.find("\"library_path\"");
    if (q == std::string::npos) { g_log += "runtime manifest without library_path; "; return; }
    auto a = text.find('"', text.find(':', q) + 1), b2 = text.find('"', a + 1);
    std::string lib = text.substr(a + 1, b2 - a - 1);
    std::string clean; for (size_t i = 0; i < lib.size(); ++i) { if (lib[i] == '\\' && i + 1 < lib.size() && lib[i + 1] == '\\') ++i; clean += lib[i]; }
    std::wstring dir = jp.substr(0, jp.find_last_of(L"\\/") + 1);
    std::wstring wl(clean.begin(), clean.end());
    if (!(wl.size() > 1 && wl[1] == L':')) wl = dir + wl;
    HMODULE rt = LoadLibraryW(wl.c_str());
    auto negotiate = rt ? (PFN_xrNegotiateLoaderRuntimeInterface)GetProcAddress(rt, "xrNegotiateLoaderRuntimeInterface") : nullptr;
    if (!negotiate) { g_log += "runtime DLL or its negotiate function not found; "; return; }
    XrNegotiateLoaderInfo li{XR_LOADER_INTERFACE_STRUCT_LOADER_INFO, XR_LOADER_INFO_STRUCT_VERSION, sizeof(XrNegotiateLoaderInfo),
                             1, XR_CURRENT_LOADER_RUNTIME_VERSION, XR_MAKE_VERSION(1, 0, 0), XR_MAKE_VERSION(1, 0x3ff, 0xfff)};
    XrNegotiateRuntimeRequest rr{XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST, XR_RUNTIME_INFO_STRUCT_VERSION, sizeof(XrNegotiateRuntimeRequest)};
    if (XR_FAILED(negotiate(&li, &rr)) || !rr.getInstanceProcAddr) { g_log += "runtime negotiation failed; "; return; }
    g_rt_gipa = rr.getInstanceProcAddr;
    void* rtc = nullptr;
    g_rt_gipa(XR_NULL_HANDLE, "xrCreateInstance", (PFN_xrVoidFunction*)&rtc);
    if (!rtc) { g_log += "runtime has no xrCreateInstance; "; return; }
    st = MH_CreateHook(rtc, (void*)&hooked_rt_create, (void**)&g_orig_rt_create);
    if (st == MH_OK) st = MH_EnableHook(rtc);
    g_log += std::string("runtime hook: ") + (st == MH_OK ? "enabled" : ("failed " + std::to_string((int)st))) + "; ";
}

// ---- runtime: trackers and per-finger curl ----
struct Tracker {
    XrHandTrackerEXT h[2]{XR_NULL_HANDLE, XR_NULL_HANDLE};
    PFN_xrLocateHandJointsEXT locate = nullptr;
    PFN_xrConvertWin32PerformanceCounterToTimeKHR to_time = nullptr;
    bool tried = false, ok = false;
    std::string status;

    bool init(XrInstance inst, XrSession session) {
        if (tried) return ok;
        tried = true;
        inst_ = inst;
        if (!g_ext_enabled) { status = "hand tracking extensions not enabled (" + g_log + ")"; return false; }
        auto gipa = g_rt_gipa ? g_rt_gipa : (PFN_xrGetInstanceProcAddr)GetProcAddress(g_loader, "xrGetInstanceProcAddr");
        PFN_xrCreateHandTrackerEXT create = nullptr;
        if (!gipa || XR_FAILED(gipa(inst, "xrCreateHandTrackerEXT", (PFN_xrVoidFunction*)&create)) ||
            XR_FAILED(gipa(inst, "xrLocateHandJointsEXT", (PFN_xrVoidFunction*)&locate)) ||
            XR_FAILED(gipa(inst, "xrConvertWin32PerformanceCounterToTimeKHR", (PFN_xrVoidFunction*)&to_time))) {
            status = "hand tracking functions missing"; return false;
        }
        XrHandTrackingDataSourceEXT srcs[2]{XR_HAND_TRACKING_DATA_SOURCE_UNOBSTRUCTED_EXT, XR_HAND_TRACKING_DATA_SOURCE_CONTROLLER_EXT};
        for (int s = 0; s < 2; ++s) {
            XrHandTrackingDataSourceInfoEXT dsi{XR_TYPE_HAND_TRACKING_DATA_SOURCE_INFO_EXT};
            dsi.requestedDataSourceCount = 2; dsi.requestedDataSources = srcs;
            XrHandTrackerCreateInfoEXT ci{XR_TYPE_HAND_TRACKER_CREATE_INFO_EXT};
            ci.next = &dsi; ci.hand = s == 0 ? XR_HAND_LEFT_EXT : XR_HAND_RIGHT_EXT; ci.handJointSet = XR_HAND_JOINT_SET_DEFAULT_EXT;
            XrResult r = create(session, &ci, &h[s]);
            if (XR_FAILED(r)) { status = "xrCreateHandTrackerEXT failed (" + std::to_string((int)r) + ")"; return false; }
        }
        ok = true; status = "hand trackers created (unobstructed + controller data sources)";
        return true;
    }

    // Curl per finger (thumb, index, middle, ring, little), 0 straight .. 1 closed, from bend angles along each
    // chain. Returns false while the hand isn't tracked.
    bool curls(XrSpace space, int side, float out[5]) {
        if (!ok) return false;
        LARGE_INTEGER pc; QueryPerformanceCounter(&pc);
        XrTime t = 0;
        if (XR_FAILED(to_time(inst_, &pc, &t))) return false;
        XrHandJointLocationEXT j[XR_HAND_JOINT_COUNT_EXT]{};
        XrHandJointLocationsEXT locs{XR_TYPE_HAND_JOINT_LOCATIONS_EXT};
        locs.jointCount = XR_HAND_JOINT_COUNT_EXT; locs.jointLocations = j;
        XrHandJointsLocateInfoEXT li{XR_TYPE_HAND_JOINTS_LOCATE_INFO_EXT};
        li.baseSpace = space; li.time = t;
        if (XR_FAILED(locate(h[side], &li, &locs)) || !locs.isActive) return false;
        auto P = [&](int i) { auto& p = j[i].pose.position; return std::array<float, 3>{p.x, p.y, p.z}; };
        auto dir = [&](int a, int b) { auto pa = P(a), pb = P(b); std::array<float, 3> d{pb[0] - pa[0], pb[1] - pa[1], pb[2] - pa[2]};
            float l = std::sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]); if (l > 1e-6f) for (auto& v : d) v /= l; return d; };
        auto bend = [&](const std::array<float, 3>& a, const std::array<float, 3>& b) {
            float c = a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; c = std::fmax(-1.f, std::fmin(1.f, c)); return std::acos(c) * 57.2958f; };
        // thumb: metacarpal(2) proximal(3) distal(4) tip(5); others: metacarpal, proximal, intermediate, distal, tip
        float th = bend(dir(2, 3), dir(3, 4)) + bend(dir(3, 4), dir(4, 5));
        out[0] = std::fmin(1.f, th / 110.f);
        for (int f = 0; f < 4; ++f) {
            int b0 = 6 + f * 5;
            float a = bend(dir(b0, b0 + 1), dir(b0 + 1, b0 + 2)) + bend(dir(b0 + 1, b0 + 2), dir(b0 + 2, b0 + 3)) +
                      bend(dir(b0 + 2, b0 + 3), dir(b0 + 3, b0 + 4));
            out[1 + f] = std::fmin(1.f, a / 230.f);
        }
        return true;
    }
    XrInstance inst_ = XR_NULL_HANDLE;
};

}  // namespace xrh
