// VOTV VR marks: UEVR C++ plugin (built against UEVR's MIT-licensed plugin headers only).
//
// A "mark" is a bookmark the player drops while testing: one controller chord (hold left grip, click the
// right stick; mirrored when left-handed) or F8 on the keyboard. Each mark writes a folder
//   <mark_dir>\<yyyy-MM-dd_HH-mm-ss_mmm>\
//       mark.json    time, trigger, runtime, level, HMD and controller poses, view, what the player aims at
//                    (the game's own lookAtActor plus line traces from the view and from the camera-manager
//                    actor), UEVR state, screenshot result
//       mirror.jpg   the game's desktop window (UEVR's flat mirror), captured off the game thread
//       eye_*        both eyes from SteamVR's compositor mirror (OpenVR runs only, if the tool is configured)
// and one log line with a fixed prefix: "[votv-mark] Mark: saved <dir> | ...". Design ported from the Sims 4
// project's marks (VR-MOD-HANDOFF.md section 12.3). Nothing here sends input to the game; the chord's stick
// click is mapped to nothing by the controls plugin while the left grip layer is held (mapper.hpp "mark").
//
// Files in UEVR's profile folder (persistent dir):
//   scripts\votv_marks.txt      live settings (key=value): mark_enabled, mark_dir, mark_key_vk, mark_chord,
//                               mark_min_interval_ms, mark_trace_cm, mark_jpeg_quality, mark_mirror_exe,
//                               mark_haptic(_amp/_ms/_freq): confirmation pulse (1 = saved, 2 = failed)
//   scripts\votv_controls.txt   read for ctl_left_handed only (mirrors the chord)
//   votv_mark_request.txt       test mailbox: its existence requests a mark, its text is the note
#include <windows.h>
#include <objidl.h>

#include <algorithm>
using std::max;   // GDI+ headers need min/max (NOMINMAX is set)
using std::min;
#include <gdiplus.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <sstream>
#include <thread>

#include "uevr/Plugin.hpp"
#include "mark_logic.hpp"

using namespace uevr;
namespace fs = std::filesystem;
using votv_marks::Json;

namespace {

double now_ms() {
    using namespace std::chrono;
    return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

std::string read_file(const fs::path& p) {
    std::ifstream f(p, std::ios::binary);
    if (!f) return {};
    std::stringstream ss; ss << f.rdbuf();
    return ss.str();
}

std::string utf8(const std::wstring& w) {
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), s.data(), n, nullptr, nullptr);
    return s;
}
std::wstring wide(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), w.data(), n);
    return w;
}

struct FVec { float x{0}, y{0}, z{0}; };
struct FRot { float pitch{0}, yaw{0}, roll{0}; };

FVec forward_of(const FRot& r) {
    const float d = 3.14159265f / 180.f;
    const float cp = std::cos(r.pitch * d), sp = std::sin(r.pitch * d), cy = std::cos(r.yaw * d), sy = std::sin(r.yaw * d);
    return {cp * cy, cp * sy, sp};
}

std::string name_of(API::UObject* o) { return o ? utf8(o->get_full_name()) : std::string{}; }

API::UObject* obj_prop(API::UObject* o, const wchar_t* name) {
    if (o == nullptr) return nullptr;
    auto p = o->get_property_data<API::UObject*>(name);
    return p ? *p : nullptr;
}

// ---- screenshot of the game's desktop window (PrintWindow + PW_RENDERFULLCONTENT works on DX swap chains) ----
struct WinFind { DWORD pid; HWND best; LONG area; };
BOOL CALLBACK enum_win(HWND h, LPARAM lp) {
    auto* f = (WinFind*)lp;
    DWORD pid = 0; GetWindowThreadProcessId(h, &pid);
    if (pid != f->pid || !IsWindowVisible(h) || GetWindow(h, GW_OWNER) != nullptr) return TRUE;
    RECT r{}; GetClientRect(h, &r);
    LONG a = (r.right - r.left) * (r.bottom - r.top);
    if (a > f->area) { f->area = a; f->best = h; }
    return TRUE;
}
HWND game_window() { WinFind f{GetCurrentProcessId(), nullptr, 0}; EnumWindows(enum_win, (LPARAM)&f); return f.best; }

bool jpeg_clsid(CLSID* out) {
    UINT n = 0, size = 0;
    Gdiplus::GetImageEncodersSize(&n, &size);
    if (size == 0) return false;
    std::vector<BYTE> buf(size);
    auto* codecs = (Gdiplus::ImageCodecInfo*)buf.data();
    Gdiplus::GetImageEncoders(n, size, codecs);
    for (UINT i = 0; i < n; ++i) if (wcscmp(codecs[i].MimeType, L"image/jpeg") == 0) { *out = codecs[i].Clsid; return true; }
    return false;
}

struct Shot { bool ok{false}; int w{0}, h{0}; std::string err; bool all_black{false}; };

Shot capture_window_jpeg(const fs::path& file, int quality) {
    Shot s;
    HWND hwnd = game_window();
    if (!hwnd) { s.err = "no game window"; return s; }
    if (IsIconic(hwnd)) { s.err = "game window minimised"; return s; }
    RECT r{}; GetClientRect(hwnd, &r);
    s.w = r.right - r.left; s.h = r.bottom - r.top;
    if (s.w <= 0 || s.h <= 0) { s.err = "empty client rect"; return s; }
    HDC wdc = GetDC(hwnd);
    HDC mdc = CreateCompatibleDC(wdc);
    HBITMAP bmp = CreateCompatibleBitmap(wdc, s.w, s.h);
    HGDIOBJ old = SelectObject(mdc, bmp);
    BOOL pw = PrintWindow(hwnd, mdc, PW_CLIENTONLY | 0x2 /* PW_RENDERFULLCONTENT */);
    SelectObject(mdc, old);
    // all-black check on a coarse grid (a failed capture of a DX window comes back black)
    {
        BITMAPINFO bi{}; bi.bmiHeader.biSize = sizeof(bi.bmiHeader); bi.bmiHeader.biWidth = s.w; bi.bmiHeader.biHeight = -s.h;
        bi.bmiHeader.biPlanes = 1; bi.bmiHeader.biBitCount = 32; bi.bmiHeader.biCompression = BI_RGB;
        std::vector<uint32_t> px((size_t)s.w * s.h);
        if (GetDIBits(mdc, bmp, 0, s.h, px.data(), &bi, DIB_RGB_COLORS) > 0) {
            bool any = false;
            for (int y = 0; y < s.h && !any; y += 16) for (int x = 0; x < s.w; x += 16) if (px[(size_t)y * s.w + x] & 0xFFFFFF) { any = true; break; }
            s.all_black = !any;
        }
    }
    {
        Gdiplus::Bitmap gb(bmp, nullptr);
        CLSID clsid;
        if (!pw) s.err = "PrintWindow failed";
        else if (!jpeg_clsid(&clsid)) s.err = "no JPEG encoder";
        else {
            Gdiplus::EncoderParameters ep{};
            ULONG q = (ULONG)std::clamp(quality, 10, 100);
            ep.Count = 1; ep.Parameter[0].Guid = Gdiplus::EncoderQuality; ep.Parameter[0].Type = Gdiplus::EncoderParameterValueTypeLong;
            ep.Parameter[0].NumberOfValues = 1; ep.Parameter[0].Value = &q;
            auto st = gb.Save(file.wstring().c_str(), &clsid, &ep);
            if (st == Gdiplus::Ok) s.ok = true; else s.err = "GDI+ save failed (" + std::to_string((int)st) + ")";
        }
    }
    DeleteObject(bmp); DeleteDC(mdc); ReleaseDC(hwnd, wdc);
    return s;
}


// ---- VR frame capture (2026-11-27, controls thread): on OpenXR/VD the desktop window and PrintWindow come back
// black, so the mark also grabs the texture UEVR hands to its framework render (the frame sent to the headset),
// on the render thread, and writes it as vr.jpg from a worker thread.
struct VrPixels { int w{0}, h{0}; std::vector<uint32_t> bgra; std::string err; int format{0}; };

VrPixels read_texture_dx11(ID3D11DeviceContext* ctx, ID3D11Texture2D* tex) {
    VrPixels out;
    if (ctx == nullptr || tex == nullptr) { out.err = "no texture"; return out; }
    D3D11_TEXTURE2D_DESC d{}; tex->GetDesc(&d);
    out.w = (int)d.Width; out.h = (int)d.Height; out.format = (int)d.Format;
    const bool rgba = d.Format == DXGI_FORMAT_R8G8B8A8_UNORM || d.Format == DXGI_FORMAT_R8G8B8A8_UNORM_SRGB || d.Format == DXGI_FORMAT_R8G8B8A8_TYPELESS;
    const bool bgra = d.Format == DXGI_FORMAT_B8G8R8A8_UNORM || d.Format == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB || d.Format == DXGI_FORMAT_B8G8R8A8_TYPELESS;
    const bool rgb10 = d.Format == DXGI_FORMAT_R10G10B10A2_UNORM || d.Format == DXGI_FORMAT_R10G10B10A2_TYPELESS;
    if (!rgba && !bgra && !rgb10) { out.err = "unsupported format " + std::to_string((int)d.Format); return out; }
    ID3D11Device* dev = nullptr; tex->GetDevice(&dev);
    D3D11_TEXTURE2D_DESC sd = d; sd.Usage = D3D11_USAGE_STAGING; sd.BindFlags = 0; sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    sd.MiscFlags = 0; sd.MipLevels = 1; sd.ArraySize = 1; sd.SampleDesc.Count = 1; sd.SampleDesc.Quality = 0;
    ID3D11Texture2D* st = nullptr;
    if (dev == nullptr || FAILED(dev->CreateTexture2D(&sd, nullptr, &st))) { out.err = "staging texture failed"; if (dev) dev->Release(); return out; }
    if (d.SampleDesc.Count > 1) ctx->ResolveSubresource(st, 0, tex, 0, d.Format); else ctx->CopySubresourceRegion(st, 0, 0, 0, 0, tex, 0, nullptr);
    D3D11_MAPPED_SUBRESOURCE m{};
    if (SUCCEEDED(ctx->Map(st, 0, D3D11_MAP_READ, 0, &m))) {
        out.bgra.resize((size_t)out.w * out.h);
        for (int y = 0; y < out.h; ++y) {
            const uint32_t* row = (const uint32_t*)((const uint8_t*)m.pData + (size_t)y * m.RowPitch);
            for (int x = 0; x < out.w; ++x) {
                uint32_t v = row[x], r, g, b;
                if (rgb10) { r = ((v >> 0) & 1023) >> 2; g = ((v >> 10) & 1023) >> 2; b = ((v >> 20) & 1023) >> 2; }
                else if (rgba) { r = v & 255; g = (v >> 8) & 255; b = (v >> 16) & 255; }
                else { b = v & 255; g = (v >> 8) & 255; r = (v >> 16) & 255; }
                out.bgra[(size_t)y * out.w + x] = 0xFF000000u | (r << 16) | (g << 8) | b;
            }
        }
        ctx->Unmap(st, 0);
    } else out.err = "map failed";
    st->Release(); dev->Release();
    return out;
}

bool save_pixels_jpeg(const VrPixels& px, const fs::path& file, int quality, std::string& err) {
    if (px.bgra.empty()) { err = px.err.empty() ? "no pixels" : px.err; return false; }
    Gdiplus::Bitmap gb(px.w, px.h, px.w * 4, PixelFormat32bppRGB, (BYTE*)px.bgra.data());
    CLSID clsid;
    if (!jpeg_clsid(&clsid)) { err = "no JPEG encoder"; return false; }
    Gdiplus::EncoderParameters ep{};
    ULONG q = (ULONG)std::clamp(quality, 10, 100);
    ep.Count = 1; ep.Parameter[0].Guid = Gdiplus::EncoderQuality; ep.Parameter[0].Type = Gdiplus::EncoderParameterValueTypeLong;
    ep.Parameter[0].NumberOfValues = 1; ep.Parameter[0].Value = &q;
    auto st = gb.Save(file.wstring().c_str(), &clsid, &ep);
    if (st != Gdiplus::Ok) { err = "GDI+ save failed (" + std::to_string((int)st) + ")"; return false; }
    return true;
}

// Run a tool with a bounded wait (SteamVR mirror capture). Returns exit code, -1 = could not start, -2 = timeout.
int run_bounded(const std::wstring& cmdline, DWORD timeout_ms) {
    STARTUPINFOW si{}; si.cb = sizeof(si); si.dwFlags = STARTF_USESHOWWINDOW; si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi{};
    std::wstring cl = cmdline;
    if (!CreateProcessW(nullptr, cl.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) return -1;
    DWORD w = WaitForSingleObject(pi.hProcess, timeout_ms);
    DWORD code = 0;
    if (w == WAIT_TIMEOUT) { TerminateProcess(pi.hProcess, 1); code = (DWORD)-2; }
    else GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    return (int)code;
}

// ---- line trace through the engine's own KismetSystemLibrary::LineTraceSingle (offsets from reflection) ----
struct Trace { bool ran{false}, hit{false}; std::string err, actor, component, bone; float distance{0}; FVec location{}; };

int prop_off(API::UStruct* s, const wchar_t* name) {
    if (!s) return -1;
    auto p = s->find_property(name);
    return p ? p->get_offset() : -1;
}

Trace line_trace(API::UObject* world_ctx, const FVec& a, const FVec& b) {
    Trace t;
    static auto lt = API::get()->find_uobject<API::UFunction>(L"Function /Script/Engine.KismetSystemLibrary.LineTraceSingle");
    static auto ksl = API::get()->find_uobject<API::UClass>(L"Class /Script/Engine.KismetSystemLibrary");
    static auto brk = API::get()->find_uobject<API::UFunction>(L"Function /Script/Engine.GameplayStatics.BreakHitResult");
    static auto gs = API::get()->find_uobject<API::UClass>(L"Class /Script/Engine.GameplayStatics");
    if (!lt || !ksl || !brk || !gs || !world_ctx) { t.err = "trace functions not found"; return t; }
    auto ksl_cdo = ksl->get_class_default_object();
    auto gs_cdo = gs->get_class_default_object();
    const int o_ctx = prop_off(lt, L"WorldContextObject"), o_s = prop_off(lt, L"Start"), o_e = prop_off(lt, L"End"),
              o_ch = prop_off(lt, L"TraceChannel"), o_self = prop_off(lt, L"bIgnoreSelf"), o_hit = prop_off(lt, L"OutHit"),
              o_ret = prop_off(lt, L"ReturnValue");
    auto hit_prop = (API::FStructProperty*)lt->find_property(L"OutHit");
    auto hit_struct = hit_prop ? hit_prop->get_struct() : nullptr;
    const int hit_size = hit_struct ? hit_struct->get_properties_size() : 0;
    const int b_hit = prop_off(brk, L"Hit"), b_dist = prop_off(brk, L"Distance"), b_loc = prop_off(brk, L"Location"),
              b_actor = prop_off(brk, L"HitActor"), b_comp = prop_off(brk, L"HitComponent"), b_bone = prop_off(brk, L"HitBoneName");
    if (o_ctx < 0 || o_s < 0 || o_e < 0 || o_ch < 0 || o_hit < 0 || o_ret < 0 || hit_size <= 0 || b_hit < 0 || b_actor < 0) {
        t.err = "trace parameter layout not found"; return t;
    }
    std::vector<uint8_t> p(lt->get_properties_size() + 16, 0);
    *(API::UObject**)&p[o_ctx] = world_ctx;
    *(FVec*)&p[o_s] = a;
    *(FVec*)&p[o_e] = b;
    p[o_ch] = 0;                       // TraceTypeQuery1 = Visibility
    if (o_self >= 0) p[o_self] = 1;    // ignore the context actor (the pawn)
    ksl_cdo->process_event(lt, p.data());
    t.ran = true;
    t.hit = p[o_ret] != 0;
    if (!t.hit) return t;
    std::vector<uint8_t> q(brk->get_properties_size() + 16, 0);
    memcpy(&q[b_hit], &p[o_hit], hit_size);
    gs_cdo->process_event(brk, q.data());
    if (b_dist >= 0) t.distance = *(float*)&q[b_dist];
    if (b_loc >= 0) t.location = *(FVec*)&q[b_loc];
    t.actor = name_of(*(API::UObject**)&q[b_actor]);
    if (b_comp >= 0) t.component = name_of(*(API::UObject**)&q[b_comp]);
    if (b_bone >= 0) { auto n = utf8(((API::FName*)&q[b_bone])->to_string()); if (n != "None") t.bone = n; }
    return t;
}

void write_trace(Json& j, const char* key, const Trace& t, const FVec& from, const FVec& dir) {
    j.key(key); j.begin_obj();
    j.key("from_cm"); j.vec3(from.x, from.y, from.z, 1);
    j.key("dir"); j.vec3(dir.x, dir.y, dir.z, 3);
    if (!t.ran) { j.kv("error", t.err); j.end_obj(); return; }
    j.kv("hit", t.hit);
    if (t.hit) {
        j.kv("actor", t.actor);
        j.kv_or_null("component", t.component);
        j.kv_or_null("bone", t.bone);
        j.kv("distance_cm", (double)t.distance, 1);
        j.key("location_cm"); j.vec3(t.location.x, t.location.y, t.location.z, 1);
    }
    j.end_obj();
}

void write_pose(Json& j, const char* key, const API::VR::Pose& p) {
    j.key(key); j.begin_obj();
    j.key("pos_m"); j.vec3(p.position.x, p.position.y, p.position.z, 3);
    j.key("rot_xyzw"); j.vec4(p.rotation.x, p.rotation.y, p.rotation.z, p.rotation.w, 4);
    j.end_obj();
}

class VotvMarks : public Plugin {
public:
    void on_initialize() override {
        dir_ = API::get()->get_persistent_dir();
        Gdiplus::GdiplusStartupInput gi;
        Gdiplus::GdiplusStartup(&gdiplus_token_, &gi, nullptr);
        load_settings(true);
        grip_ = API::VR::get_action_handle("/actions/default/in/Grip");
        click_ = API::VR::get_action_handle("/actions/default/in/JoystickClick");
        API::get()->log_info("[votv-mark] start: plugin votv_marks v1, marks in %s, chord %s, key vk 0x%02X",
                             mark_dir().string().c_str(), chord_ ? (left_handed_ ? "right grip + left stick click" : "left grip + right stick click") : "off", key_vk_);
    }

    void on_pre_engine_tick(API::UGameEngine*, float) override {
        const double t = now_ms();
        if (t - settings_check_t_ > 1000) { settings_check_t_ = t; load_settings(false); poll_request_file(); }
        if (!enabled_) return;
        if (pending_fail_.exchange(false)) pulse(true);   // a capture failed on the worker thread

        std::string trigger;
        // Controller chord (UEVR's own actions, so it works whatever the controls plugin does with XInput).
        if (chord_ && grip_ && click_) {
            auto mod_src = left_handed_ ? API::VR::get_right_joystick_source() : API::VR::get_left_joystick_source();
            auto btn_src = left_handed_ ? API::VR::get_left_joystick_source() : API::VR::get_right_joystick_source();
            const bool mod = API::VR::is_action_active(grip_, mod_src);
            const bool btn = API::VR::is_action_active(click_, btn_src);
            if (chord_trigger_.update(chord_state_.update(mod, btn), t))
                trigger = left_handed_ ? "controller: right grip + left stick click" : "controller: left grip + right stick click";
        }
        // Keyboard key, only while the game window has focus.
        if (trigger.empty() && key_vk_ != 0) {
            const bool down = game_has_focus() && (GetAsyncKeyState(key_vk_) & 0x8000) != 0;
            if (key_trigger_.update(down, t)) { char b[32]; snprintf(b, sizeof(b), "keyboard: vk 0x%02X", key_vk_); trigger = b; }
        }
        if (trigger.empty() && !pending_request_.empty()) { trigger = "request file"; }
        if (trigger.empty()) return;
        std::string note;
        if (trigger == "request file") { note = pending_note_; pending_request_.clear(); pending_note_.clear(); }
        make_mark(trigger, note);
    }

private:
    // Mark feedback (user 2026-11-27: vibration is fine for mark confirmation only): one short pulse on the hand
    // that clicked the stick when the mark is written; two pulses when it failed (folder, busy, or capture).
    // Called on the game thread only. Uses the C API directly (API.hpp's wrapper has its arguments in a different order).
    void pulse(bool failed) {
        if (!haptic_) return;
        auto src = left_handed_ ? API::VR::get_left_joystick_source() : API::VR::get_right_joystick_source();
        auto vr = API::get()->param()->vr;
        vr->trigger_haptic_vibration(0.0f, haptic_s_, haptic_freq_, haptic_amp_, src);
        if (failed) vr->trigger_haptic_vibration(haptic_s_ + 0.12f, haptic_s_, haptic_freq_, haptic_amp_, src);
        API::get()->log_info("[votv-mark] feedback: %s pulse (%.0f ms, amplitude %.2f, %s hand)", failed ? "double (failed)" : "single (ok)",
                             haptic_s_ * 1000.f, haptic_amp_, left_handed_ ? "left" : "right");
    }

    fs::path dir_;
    ULONG_PTR gdiplus_token_{0};
    double settings_check_t_{0};
    fs::file_time_type settings_mtime_{}, ctl_mtime_{};
    bool enabled_{true}, chord_{true}, left_handed_{false};
    int key_vk_{VK_F8};
    int jpeg_quality_{90};
    float trace_cm_{2000};
    std::string mark_dir_setting_, mirror_exe_;
    UEVR_ActionHandle grip_{nullptr}, click_{nullptr};
    votv_marks::Chord chord_state_;
    votv_marks::Trigger chord_trigger_, key_trigger_;
    std::string pending_request_, pending_note_;
    std::atomic<int> in_flight_{0};
    // VR frame request: set by a mark, served by the next framework render (render thread)
    std::mutex vr_mtx_;
    fs::path vr_folder_;
    std::atomic<bool> vr_want_{false};

public:
    void on_post_render_vr_framework_dx11(ID3D11DeviceContext* context, ID3D11Texture2D* texture, ID3D11RenderTargetView*) override {
        if (!vr_want_.exchange(false)) return;
        fs::path folder;
        { std::scoped_lock lk(vr_mtx_); folder = vr_folder_; }
        VrPixels px = read_texture_dx11(context, texture);
        const int q = jpeg_quality_;
        std::thread([folder, q, px = std::move(px)]() {
            std::string err;
            bool ok = save_pixels_jpeg(px, folder / "vr.jpg", q, err);
            API::get()->log_info("[votv-mark] Mark: VR frame %s %s (%dx%d, format %d)%s", folder.string().c_str(), ok ? "ok" : "FAILED",
                                 px.w, px.h, px.format, err.empty() ? "" : (" " + err).c_str());
        }).detach();
    }
private:
    std::atomic<bool> pending_fail_{false};
    bool haptic_{true};
    float haptic_amp_{0.6f}, haptic_s_{0.06f}, haptic_freq_{1.0f};
    int count_{0};

    fs::path mark_dir() const { return mark_dir_setting_.empty() ? dir_ / "marks" : fs::path(wide(mark_dir_setting_)); }

    bool game_has_focus() {
        HWND fg = GetForegroundWindow();
        DWORD pid = 0; GetWindowThreadProcessId(fg, &pid);
        return fg != nullptr && pid == GetCurrentProcessId();
    }

    void load_settings(bool first) {
        fs::path p = dir_ / "scripts" / "votv_marks.txt";
        fs::path c = dir_ / "scripts" / "votv_controls.txt";
        std::error_code ec, ec2;
        auto mt = fs::last_write_time(p, ec);
        auto ct = fs::last_write_time(c, ec2);
        if (!first && mt == settings_mtime_ && ct == ctl_mtime_) return;
        settings_mtime_ = mt; ctl_mtime_ = ct;
        const std::string s = read_file(p);
        using namespace votv_marks;
        enabled_ = setting_num(s, "mark_enabled", 1) != 0;
        chord_ = setting_num(s, "mark_chord", 1) != 0;
        key_vk_ = (int)setting_num(s, "mark_key_vk", VK_F8);    // 0 = no keyboard key; 0x77 = F8
        const double iv = setting_num(s, "mark_min_interval_ms", 1000);
        chord_trigger_.min_interval_ms = key_trigger_.min_interval_ms = iv;
        trace_cm_ = (float)setting_num(s, "mark_trace_cm", 2000);
        jpeg_quality_ = (int)setting_num(s, "mark_jpeg_quality", 90);
        haptic_ = setting_num(s, "mark_haptic", 1) != 0;   // mark confirmation only (user exception 2026-11-27); game input stays haptics-off
        haptic_amp_ = (float)setting_num(s, "mark_haptic_amp", 0.6);
        haptic_s_ = (float)setting_num(s, "mark_haptic_ms", 60) / 1000.f;
        haptic_freq_ = (float)setting_num(s, "mark_haptic_freq", 1.0);
        mark_dir_setting_ = setting_str(s, "mark_dir");
        mirror_exe_ = setting_str(s, "mark_mirror_exe");
        left_handed_ = setting_num(read_file(c), "ctl_left_handed", 0) != 0;
        if (!first) API::get()->log_info("[votv-mark] settings reloaded (%s): enabled=%d chord=%d left_handed=%d key=0x%02X dir=%s",
                                         s.empty() ? "file missing, defaults" : "file", enabled_, chord_, left_handed_, key_vk_, mark_dir().string().c_str());
    }

    void poll_request_file() {
        fs::path p = dir_ / "votv_mark_request.txt";
        std::error_code ec;
        if (!fs::exists(p, ec) || !pending_request_.empty()) return;
        pending_note_ = read_file(p);
        while (!pending_note_.empty() && (pending_note_.back() == '\n' || pending_note_.back() == '\r')) pending_note_.pop_back();
        fs::remove(p, ec);
        pending_request_ = "1";
    }

    void make_mark(const std::string& trigger, const std::string& note) {
        if (in_flight_ >= 2) { API::get()->log_warn("[votv-mark] Mark: skipped (%d captures still being written)", in_flight_.load()); pulse(true); return; }
        SYSTEMTIME st; GetLocalTime(&st);
        const std::string id = votv_marks::folder_name(st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
        char local[64];
        snprintf(local, sizeof(local), "%04d-%02d-%02d %02d:%02d:%02d.%03d", st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
        const fs::path folder = mark_dir() / id;
        std::error_code ec;
        fs::create_directories(folder, ec);
        if (ec) { API::get()->log_error("[votv-mark] Mark: could not create %s (%s)", folder.string().c_str(), ec.message().c_str()); pulse(true); return; }
        ++count_;

        // Game and VR state, read now on the game thread.
        Json j;
        j.begin_obj();
        j.kv("schema", 1);
        j.kv("id", id);
        j.kv("local_time", std::string(local));
        j.kv("mark_number_this_session", count_);
        j.kv("trigger", trigger);
        j.kv_or_null("note", note);
        std::string summary = gather_state(j);
        j.kv("screenshot", std::string("pending"));   // replaced by the worker
        j.end_obj();
        write_text(folder / "mark.json", j.out);

        API::get()->log_info("[votv-mark] Mark: saved %s | local %s | %s | %s", folder.string().c_str(), local, trigger.c_str(), summary.c_str());
        API::get()->dispatch_lua_event("votv_mark", folder.string().c_str());
        pulse(false);

        // The frame actually sent to the headset (vr.jpg), grabbed on the next framework render.
        { std::scoped_lock lk(vr_mtx_); vr_folder_ = folder; }
        vr_want_ = true;
        // Screenshot and (SteamVR) both eyes off the game thread, then the final mark.json.
        ++in_flight_;
        std::string json_body = j.out;
        const bool openvr = API::VR::is_openvr();
        std::thread([this, folder, json_body, openvr, q = jpeg_quality_, mirror = mirror_exe_]() mutable {
            const double t0 = now_ms();
            Shot s = capture_window_jpeg(folder / "mirror.jpg", q);
            const double t1 = now_ms();
            Json k;
            k.begin_obj();
            k.kv("file", s.ok ? std::string("mirror.jpg") : std::string());
            k.kv("source", std::string("game desktop window (UEVR flat mirror), PrintWindow"));
            k.kv("ok", s.ok);
            if (!s.err.empty()) k.kv("error", s.err);
            k.kv("width", s.w); k.kv("height", s.h);
            k.kv("all_black", s.all_black);
            k.kv("capture_ms", t1 - t0, 0);
            if (openvr && !mirror.empty()) {
                const fs::path prefix = folder / "eye";
                int rc = run_bounded(L"\"" + wide(mirror) + L"\" \"" + prefix.wstring() + L"\" snap 1", 10000);
                k.key("eyes"); k.begin_obj();
                k.kv("source", std::string("SteamVR compositor mirror (openvr_mirror_capture snap 1)"));
                k.kv("exit_code", rc);
                k.kv("files_prefix", std::string("eye"));
                k.end_obj();
            } else {
                k.key("eyes"); k.begin_obj();
                k.kv("source", std::string(openvr ? "not configured (mark_mirror_exe empty)" : "none: OpenXR (VDXR) has no compositor mirror; mirror.jpg is the desktop view"));
                k.end_obj();
            }
            k.end_obj();
            // splice the screenshot object into the mark.json written earlier
            const std::string marker = "\"screenshot\": \"pending\"";
            auto pos = json_body.find(marker);
            if (pos != std::string::npos) {
                std::string obj = k.out;   // re-indent one level
                std::string ind;
                for (char c : obj) { ind += c; if (c == '\n') ind += "  "; }
                json_body.replace(pos, marker.size(), "\"screenshot\": " + ind);
            }
            write_text(folder / "mark.json", json_body);
            API::get()->log_info("[votv-mark] Mark: screenshot %s %s (%dx%d, %.0f ms)%s", folder.string().c_str(),
                                 s.ok ? "ok" : "FAILED", s.w, s.h, t1 - t0, s.err.empty() ? "" : (" " + s.err).c_str());
            if (!s.ok || s.all_black) pending_fail_ = true;
            --in_flight_;
        }).detach();
    }

    static void write_text(const fs::path& p, const std::string& text) {
        const fs::path tmp = p.string() + ".tmp";
        { std::ofstream f(tmp, std::ios::binary | std::ios::trunc); f << text << "\n"; }
        std::error_code ec;
        fs::rename(tmp, p, ec);
        if (ec) { fs::remove(p, ec); fs::rename(tmp, p, ec); }
    }

    // Writes the state keys into j and returns a one-line summary for the log.
    std::string gather_state(Json& j) {
        const bool xr = API::VR::is_openxr(), vr = API::VR::is_openvr();
        j.kv("runtime", std::string(xr ? "OpenXR" : (vr ? "OpenVR" : "none")));
        j.kv("hmd_active", API::VR::is_hmd_active());

        auto engine = (API::UObject*)API::get()->get_engine();
        auto viewport = obj_prop(engine, L"GameViewport");
        auto world = obj_prop(viewport, L"World");
        auto pc = API::get()->get_player_controller(0);
        auto pawn = API::get()->get_local_pawn(0);
        auto pcm = obj_prop(pc, L"PlayerCameraManager");
        const std::string world_name = name_of(world);

        j.key("game"); j.begin_obj();
        j.kv_or_null("world", world_name);
        j.kv_or_null("player_controller", name_of(pc));
        j.kv_or_null("pawn", name_of(pawn));
        if (pawn) {
            struct { FVec ret; } loc{};
            pawn->call_function(L"K2_GetActorLocation", &loc);
            j.key("pawn_location_cm"); j.vec3(loc.ret.x, loc.ret.y, loc.ret.z, 1);
        }
        FVec view_loc{}, view_dir{1, 0, 0};
        FRot view_rot{};
        if (pcm) {
            struct { FVec ret; } l{}; struct { FRot ret; } r{};
            pcm->call_function(L"GetCameraLocation", &l);
            pcm->call_function(L"GetCameraRotation", &r);
            view_loc = l.ret; view_rot = r.ret; view_dir = forward_of(view_rot);
            j.key("view"); j.begin_obj();
            j.key("location_cm"); j.vec3(view_loc.x, view_loc.y, view_loc.z, 1);
            j.key("rotation_pyr_deg"); j.vec3(view_rot.pitch, view_rot.yaw, view_rot.roll, 2);
            j.end_obj();
        }
        // The game's own aim result (mainPlayer_C, from its arm() ray; with votv_hand_aim.lua it starts at the hand).
        auto look = obj_prop(pawn, L"lookAtActor");
        auto grab = obj_prop(pawn, L"grabbing_actor");
        j.kv_or_null("look_at_actor", name_of(look));
        if (look && pcm) {
            struct { FVec ret; } a{};
            look->call_function(L"K2_GetActorLocation", &a);
            const float dx = a.ret.x - view_loc.x, dy = a.ret.y - view_loc.y, dz = a.ret.z - view_loc.z;
            j.kv("look_at_actor_distance_from_view_cm", (double)std::sqrt(dx * dx + dy * dy + dz * dz), 1);
        }
        j.kv_or_null("grabbing_actor", name_of(grab));
        // Our own line traces: from the view (head gaze) and from the camera-manager actor (moved to the right
        // hand by votv_hand_aim.lua when hand aim is on; otherwise it sits at the view).
        Trace gaze, hand;
        API::UObject* ctx = pawn ? pawn : pc;
        if (pcm && ctx) {
            const FVec e{view_loc.x + view_dir.x * trace_cm_, view_loc.y + view_dir.y * trace_cm_, view_loc.z + view_dir.z * trace_cm_};
            gaze = line_trace(ctx, view_loc, e);
            write_trace(j, "gaze_trace", gaze, view_loc, view_dir);
            struct { FVec ret; } hl{}; struct { FVec ret; } hf{};
            pcm->call_function(L"K2_GetActorLocation", &hl);
            pcm->call_function(L"GetActorForwardVector", &hf);
            const FVec he{hl.ret.x + hf.ret.x * trace_cm_, hl.ret.y + hf.ret.y * trace_cm_, hl.ret.z + hf.ret.z * trace_cm_};
            hand = line_trace(ctx, hl.ret, he);
            write_trace(j, "camera_manager_actor_trace", hand, hl.ret, hf.ret);
        }
        j.kv("trace_length_cm", (double)trace_cm_, 0);
        j.end_obj();

        // VR poses in UEVR's standing space (metres; UEVR's runtime coordinates).
        j.key("vr"); j.begin_obj();
        const auto so = API::VR::get_standing_origin();
        j.key("standing_origin_m"); j.vec3(so.x, so.y, so.z, 3);
        write_pose(j, "hmd", API::VR::get_pose(API::VR::get_hmd_index()));
        const auto li = API::VR::get_left_controller_index(), ri = API::VR::get_right_controller_index();
        j.key("left"); j.begin_obj(); write_pose(j, "grip", API::VR::get_grip_pose(li)); write_pose(j, "aim", API::VR::get_aim_pose(li)); j.end_obj();
        j.key("right"); j.begin_obj(); write_pose(j, "grip", API::VR::get_grip_pose(ri)); write_pose(j, "aim", API::VR::get_aim_pose(ri)); j.end_obj();
        j.end_obj();

        j.key("uevr"); j.begin_obj();
        for (const char* k : {"VR_AimMethod", "VR_2DScreenMode", "VR_DecoupledPitch", "VR_SnapTurn", "VR_RenderingMethod"})
            j.kv(k, API::VR::get_mod_value<std::string>(k));
        j.end_obj();

        std::string sum = "world " + (world_name.empty() ? std::string("?") : world_name);
        sum += " | look_at " + (look ? name_of(look) : std::string("none"));
        if (gaze.ran) sum += " | gaze " + (gaze.hit ? gaze.actor + " @" + std::to_string((int)gaze.distance) + "cm" : std::string("no hit"));
        else if (!gaze.err.empty()) sum += " | gaze trace: " + gaze.err;
        sum += std::string(" | runtime ") + (xr ? "OpenXR" : (vr ? "OpenVR" : "none"));
        return sum;
    }
};

VotvMarks g_plugin{};

}  // namespace
