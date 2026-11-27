// VOTV VR laser pointer for flat menus: UEVR C++ plugin (built against UEVR's MIT-licensed plugin headers only).
//
// Active only while UEVR's 2D screen mode is on (the menu script turns it on in the main menu), the headset
// is active and the game window has focus. Then it:
//   - casts a ray from the aiming hand (right; left with ctl_left_handed=1 in scripts\votv_controls.txt) onto
//     a model of UEVR's flat screen (pointer_math.hpp: follows head yaw, not pitch; live-calibrated),
//   - moves the OS cursor to the hit point inside the game window (plus a 1 px relative move so Slate sees
//     a hover), trigger = left click, stick up/down = mouse wheel. The recipe is the one proven on the menus
//     on 2026-11-27 02:13 (SendInput, 40-byte INPUT, move before click; PostMessage didn't work),
//   - draws a dot at the hit point into the game's backbuffer (D3D11 ClearView), which UEVR's 2D screen
//     shows: the dot is the visible cursor (the game shows none in the menu).
// Exports `extern "C" bool votv_pointer_active()` for votv_controls.dll, which then sends nothing for the
// right trigger, right stick and A (agreed with the controls thread, 2026-11-27).
//
// Files in UEVR's profile folder (persistent dir):
//   scripts\votv_pointer.txt   live settings (key=value, re-read every second; see Settings)
//   votv_pointer_trace.txt     activation, hits (rate-limited), clicks, wheel, errors, with ms timestamps
#include <windows.h>
#include <d3d11_1.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdarg>
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include <string>

#include "uevr/Plugin.hpp"
#include "pointer_math.hpp"

using namespace uevr;
namespace fs = std::filesystem;

static std::atomic<bool> g_active{false};

extern "C" __declspec(dllexport) bool votv_pointer_active() { return g_active.load(); }

namespace {

double now_ms() {
    using namespace std::chrono;
    return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

std::map<std::string, std::string> parse_kv(const fs::path& p) {
    std::map<std::string, std::string> kv;
    std::ifstream f(p);
    std::string line;
    while (std::getline(f, line)) {
        auto hash = line.find('#');
        if (hash != std::string::npos) line = line.substr(0, hash);
        auto eq = line.find('=');
        if (eq == std::string::npos) continue;
        auto trim = [](std::string s) {
            s.erase(0, s.find_first_not_of(" \t\r\n"));
            s.erase(s.find_last_not_of(" \t\r\n") + 1);
            return s;
        };
        kv[trim(line.substr(0, eq))] = trim(line.substr(eq + 1));
    }
    return kv;
}

UINT send_mouse(DWORD flags, LONG dx = 0, LONG dy = 0, DWORD data = 0) {
    INPUT in{};
    in.type = INPUT_MOUSE;
    in.mi.dx = dx;
    in.mi.dy = dy;
    in.mi.mouseData = data;
    in.mi.dwFlags = flags;
    return SendInput(1, &in, sizeof(INPUT));  // events inserted (1) or 0 (blocked, e.g. UIPI)
}

// One line of evidence per click (live session 2026-11-27: clicks counted in the trace weren't proven to reach
// the menu): SendInput result, last error, foreground window owner and title, OS cursor position.
std::string click_context(UINT sent) {
    DWORD err = sent ? 0 : GetLastError();
    HWND fg = GetForegroundWindow();
    DWORD pid = 0;
    GetWindowThreadProcessId(fg, &pid);
    char title[128]{};
    GetWindowTextA(fg, title, sizeof(title));
    POINT cur{};
    GetCursorPos(&cur);
    char buf[400];
    snprintf(buf, sizeof(buf), "SendInput=%u err=%lu fg='%s' %s cursor %ld,%ld", sent, err, title,
             pid == GetCurrentProcessId() ? "(game)" : "(NOT the game)", cur.x, cur.y);
    return buf;
}

struct Settings {
    bool enabled = true;
    votv::ScreenModel screen;
    float trigger_on = 0.6f, trigger_off = 0.4f;
    float wheel_threshold = 0.6f;
    double wheel_repeat_ms = 150;
    int dot_px = 10;
    float dot_r = 1.0f, dot_g = 0.15f, dot_b = 0.15f;
    bool left_handed = false;
    bool trace_hits = true;
    bool dot_desktop = true;      // game backbuffer (PC monitor)
    bool dot_framework = false;   // UEVR framework texture: drawn there 02:39, not visible in the headset
    float dot_framework_scale = 1.0f;
    bool dot_ui = true;           // UEVR's UI render target (Slate / menus)
    bool dot_scene = true;        // UEVR's scene render target
    bool dot_umg = true;          // tell the menu Lua script to draw its green UMG dot at the mouse
    bool calibrate = false;       // ptr_calibrate=1: trigger records the 4 screen corners, no clicks
    bool click = true;            // ptr_click=0: never click (pointing only)
};

class VotvPointer : public Plugin {
public:
    void on_initialize() override {
        dir_ = API::get()->get_persistent_dir();
        trace_.open(dir_ / "votv_pointer_trace.txt", std::ios::app);
        log("start: plugin votv_pointer v1, profile dir %s", dir_.string().c_str());
        load_settings(true);
        trigger_action_ = API::VR::get_action_handle("/actions/default/in/Trigger");
    }

    void on_pre_engine_tick(API::UGameEngine*, float) override {
        const double t = now_ms();
        if (t - settings_t_ > 1000) {
            settings_t_ = t;
            load_settings(false);
            API::get()->dispatch_lua_event("votv_ptr", s_.dot_umg ? "umg_dot=1" : "umg_dot=0");  // menu script's UMG dot switch
        }

        std::string why;
        bool twod = false;
        try { twod = API::VR::get_mod_value<bool>("VR_2DScreenMode"); } catch (...) {}
        if (!s_.enabled) why = "disabled";
        else if (!twod) why = "not in 2D screen mode";
        else if (!API::VR::is_hmd_active()) why = "hmd inactive";
        else if (!game_hwnd()) why = "game not focused";
        const bool active = why.empty();
        if (active != g_active.load()) {
            if (!active) release_all();
            g_active = active;
            log(active ? "active (2D screen, %s hand)" : "inactive: %s", active ? (s_.left_handed ? "left" : "right") : why.c_str());
            if (active) {
                auto hp = API::VR::get_pose(API::VR::get_hmd_index());
                votv::Quat hq{hp.rotation.x, hp.rotation.y, hp.rotation.z, hp.rotation.w};
                auto f = votv::forward_of(hq);
                log("  hmd pos (%.2f %.2f %.2f) forward (%.2f %.2f %.2f)", hp.position.x, hp.position.y, hp.position.z, f.x, f.y, f.z);
            }
        }
        if (!active) { dot_visible_ = false; return; }

        // Ray from the aiming hand onto the screen model.
        auto hp = API::VR::get_pose(API::VR::get_hmd_index());
        auto idx = s_.left_handed ? API::VR::get_left_controller_index() : API::VR::get_right_controller_index();
        auto ap = API::VR::get_aim_pose(idx);
        votv::Vec3 head{hp.position.x, hp.position.y, hp.position.z};
        votv::Quat hq{hp.rotation.x, hp.rotation.y, hp.rotation.z, hp.rotation.w};
        votv::Vec3 origin{ap.position.x, ap.position.y, ap.position.z};
        votv::Quat aq{ap.rotation.x, ap.rotation.y, ap.rotation.z, ap.rotation.w};
        auto screen = votv::place_screen(head, hq, s_.screen);
        std::optional<votv::Hit> hit;
        if (screen) hit = votv::hit_screen(*screen, origin, votv::forward_of(aq));

        HWND hwnd = game_hwnd();
        RECT rc{};
        GetClientRect(hwnd, &rc);
        const int cw = rc.right - rc.left, ch = rc.bottom - rc.top;
        if (hit && hit->on_screen && cw > 0 && ch > 0) {
            dot_u_ = hit->u; dot_v_ = hit->v; dot_visible_ = true;
            POINT pt{(LONG)std::lround(hit->u * (cw - 1)), (LONG)std::lround(hit->v * (ch - 1))};
            last_client_ = pt;
            ClientToScreen(hwnd, &pt);
            if (std::abs(pt.x - last_pt_.x) + std::abs(pt.y - last_pt_.y) >= 1) {
                SetCursorPos(pt.x, pt.y);
                send_mouse(MOUSEEVENTF_MOVE, 1, 0);   // hover: Slate needs a move event
                send_mouse(MOUSEEVENTF_MOVE, -1, 0);
                last_pt_ = pt;
            }
            if (s_.trace_hits && t - hit_log_t_ > 2000) {
                hit_log_t_ = t;
                log("hit u %.3f v %.3f -> client %ld,%ld of %dx%d (ray %.2f m)", hit->u, hit->v,
                    (long)std::lround(hit->u * (cw - 1)), (long)std::lround(hit->v * (ch - 1)), cw, ch, hit->t);
            }
        } else {
            dot_visible_ = false;
            if (s_.trace_hits && t - hit_log_t_ > 2000) {
                hit_log_t_ = t;
                if (hit) log("off screen: u %.3f v %.3f", hit->u, hit->v); else log("no hit (pointing away)");
            }
        }

        // Trigger = left button (only starts a click while on the screen; a release always goes out).
        auto src = s_.left_handed ? API::VR::get_left_joystick_source() : API::VR::get_right_joystick_source();
        float trig = API::VR::is_action_active(trigger_action_, src) ? 1.f : 0.f;
        trigger_.on = s_.trigger_on; trigger_.off = s_.trigger_off;
        int edge = trigger_.update(trig);
        if (s_.calibrate) {
            // Calibration (ptr_calibrate=1): no clicks; trigger records the screen corners in order
            // top-left, top-right, bottom-right, bottom-left, then the fitted screen is applied and saved.
            if (edge == 1) record_corner(head, hq, origin, votv::forward_of(aq));
            return;
        }
        if (edge == 1 && dot_visible_ && s_.click) {
            send_mouse(MOUSEEVENTF_MOVE, 1, 0); send_mouse(MOUSEEVENTF_MOVE, -1, 0);
            UINT sent = send_mouse(MOUSEEVENTF_LEFTDOWN); button_down_ = true;
            log("click down at u %.3f v %.3f (target client %ld,%ld): %s", dot_u_.load(), dot_v_.load(),
                last_client_.x, last_client_.y, click_context(sent).c_str());
        } else if (edge == -1 && button_down_) {
            UINT sent = send_mouse(MOUSEEVENTF_LEFTUP); button_down_ = false;
            log("click up: %s", click_context(sent).c_str());
        }

        // Stick up/down = wheel, repeating while held.
        auto axis = API::VR::get_joystick_axis(src);
        if (std::fabs(axis.y) >= s_.wheel_threshold) {
            if (t - wheel_t_ >= s_.wheel_repeat_ms) {
                wheel_t_ = t;
                send_mouse(MOUSEEVENTF_WHEEL, 0, 0, (DWORD)(axis.y > 0 ? WHEEL_DELTA : -WHEEL_DELTA));
                log("wheel %s", axis.y > 0 ? "up" : "down");
            }
        } else {
            wheel_t_ = 0;
        }
    }

    // Dot into the game's backbuffer, which UEVR's 2D screen shows.
    void on_present() override {
        if (!g_active.load() || !dot_visible_) return;
        auto r = API::get()->param()->renderer;
        if (r == nullptr || r->renderer_type != UEVR_RENDERER_D3D11 || r->swapchain == nullptr) {
            if (!warned_renderer_) { warned_renderer_ = true; log("dot: not D3D11 or no swapchain, dot disabled"); }
            return;
        }
        auto sc = (IDXGISwapChain*)r->swapchain;
        ID3D11Texture2D* bb = nullptr;
        if (FAILED(sc->GetBuffer(0, __uuidof(ID3D11Texture2D), (void**)&bb)) || bb == nullptr) return;
        D3D11_TEXTURE2D_DESC desc{};
        bb->GetDesc(&desc);
        ID3D11Device* dev = nullptr;
        bb->GetDevice(&dev);
        if (dev != nullptr) {
            if (bb != rtv_tex_ || rtv_ == nullptr) {
                if (rtv_) { rtv_->Release(); rtv_ = nullptr; }
                if (FAILED(dev->CreateRenderTargetView(bb, nullptr, &rtv_))) rtv_ = nullptr;
                rtv_tex_ = bb;
                log("dot: backbuffer %ux%u fmt %d, rtv %s", desc.Width, desc.Height, (int)desc.Format, rtv_ ? "ok" : "FAILED");
            }
            ID3D11DeviceContext* ctx = nullptr;
            dev->GetImmediateContext(&ctx);
            if (ctx && rtv_ && s_.dot_desktop) draw_dot(ctx, rtv_, desc.Width, desc.Height, s_.dot_px);
            if (ctx) ctx->Release();
            dev->Release();
        }
        bb->Release();  // rtv_tex_ is only compared, never dereferenced
    }

    // Live session 2026-11-27 02:37: the backbuffer dot showed on the PC monitor only, not in the headset (UEVR's
    // 2D screen doesn't sample the final backbuffer). Second target: the texture UEVR hands plugins after it
    // renders its own framework layer, which is composited into the headset view. Which one reaches the headset
    // is logged once (sizes) and checked live; ptr_dot_desktop / ptr_dot_framework switch each target.
    void on_post_render_vr_framework_dx11(ID3D11DeviceContext* context, ID3D11Texture2D* texture, ID3D11RenderTargetView* rtv) override {
        if (!g_active.load() || !dot_visible_ || !s_.dot_framework || context == nullptr || texture == nullptr || rtv == nullptr) return;
        D3D11_TEXTURE2D_DESC desc{};
        texture->GetDesc(&desc);
        if (!logged_framework_) {
            logged_framework_ = true;
            log("dot: framework texture %ux%u fmt %d (drawing there too)", desc.Width, desc.Height, (int)desc.Format);
        }
        draw_dot(context, rtv, desc.Width, desc.Height, std::max(4, (int)std::lround(s_.dot_px * desc.Width / 2560.0 * s_.dot_framework_scale)));
    }

    // Live 2026-11-27 02:39: neither the backbuffer dot (Present) nor the framework-texture dot reached the
    // headset; UEVR showed the framework texture as 2560x1440 BGRA but the 2D screen doesn't use it. UEVR's own
    // render targets are the next candidates: its UI target (where it redirects Slate, i.e. the game's menus)
    // and its scene target. Drawn right after Slate drew the window (render thread). Each is switchable
    // (ptr_dot_ui, ptr_dot_scene) and its size is logged once.
    void on_post_slate_draw_window(UEVR_FSlateRHIRendererHandle, UEVR_FViewportInfoHandle) override {
        if (!g_active.load() || !dot_visible_) return;
        auto r = API::get()->param()->renderer;
        if (r == nullptr || r->renderer_type != UEVR_RENDERER_D3D11) return;
        if (s_.dot_ui) draw_into_uevr_rt(API::StereoHook::get_ui_render_target(), ui_rt_, "UI");
        if (s_.dot_scene) draw_into_uevr_rt(API::StereoHook::get_scene_render_target(), scene_rt_, "scene");
    }

    struct RtCache { void* tex = nullptr; ID3D11RenderTargetView* rtv = nullptr; bool logged = false; bool failed = false; };

    void draw_into_uevr_rt(API::FRHITexture2D* rhi, RtCache& c, const char* what) {
        if (rhi == nullptr) { if (!c.logged) { c.logged = true; log("dot: no UEVR %s render target", what); } return; }
        auto tex = (ID3D11Texture2D*)rhi->get_native_resource();
        if (tex == nullptr) return;
        if (tex != c.tex) {
            if (c.rtv) { c.rtv->Release(); c.rtv = nullptr; }
            c.tex = tex; c.failed = false;
            ID3D11Device* dev = nullptr;
            tex->GetDevice(&dev);
            if (dev) {
                if (FAILED(dev->CreateRenderTargetView(tex, nullptr, &c.rtv))) { c.rtv = nullptr; c.failed = true; }
                dev->Release();
            }
            D3D11_TEXTURE2D_DESC d{};
            tex->GetDesc(&d);
            log("dot: UEVR %s render target %ux%u fmt %d bind 0x%x, rtv %s", what, d.Width, d.Height, (int)d.Format, d.BindFlags,
                c.rtv ? "ok" : "FAILED");
        }
        if (c.rtv == nullptr) return;
        ID3D11Device* dev = nullptr;
        tex->GetDevice(&dev);
        if (!dev) return;
        ID3D11DeviceContext* ctx = nullptr;
        dev->GetImmediateContext(&ctx);
        if (ctx) {
            D3D11_TEXTURE2D_DESC d{};
            tex->GetDesc(&d);
            draw_dot(ctx, c.rtv, d.Width, d.Height, std::max(4, (int)std::lround(s_.dot_px * d.Width / 2560.0)));
            ctx->Release();
        }
        dev->Release();
    }

    void draw_dot(ID3D11DeviceContext* ctx, ID3D11RenderTargetView* rtv, UINT w, UINT hgt, int px) {
        ID3D11DeviceContext1* ctx1 = nullptr;
        if (FAILED(ctx->QueryInterface(__uuidof(ID3D11DeviceContext1), (void**)&ctx1)) || ctx1 == nullptr) return;
        const LONG cx = (LONG)std::lround(dot_u_ * (w - 1)), cy = (LONG)std::lround(dot_v_ * (hgt - 1));
        const LONG h = std::max(2, px / 2);
        const float black[4] = {0, 0, 0, 1};
        const float col[4] = {s_.dot_r, s_.dot_g, s_.dot_b, 1};
        D3D11_RECT outer{cx - h - 2, cy - h - 2, cx + h + 2, cy + h + 2};
        D3D11_RECT inner{cx - h, cy - h, cx + h, cy + h};
        ctx1->ClearView(rtv, black, &outer, 1);
        ctx1->ClearView(rtv, col, &inner, 1);
        ctx1->Release();
    }

    void on_device_reset() override {
        if (rtv_) { rtv_->Release(); rtv_ = nullptr; }
        rtv_tex_ = nullptr;
        for (RtCache* c : {&ui_rt_, &scene_rt_}) { if (c->rtv) c->rtv->Release(); *c = RtCache{}; }
    }

private:
    HWND game_hwnd() {
        HWND fg = GetForegroundWindow();
        DWORD pid = 0;
        GetWindowThreadProcessId(fg, &pid);
        return pid == GetCurrentProcessId() ? fg : nullptr;
    }

    void release_all() {
        if (button_down_) { send_mouse(MOUSEEVENTF_LEFTUP); button_down_ = false; log("release: button up"); }
        trigger_.down = false;
        dot_visible_ = false;
        last_pt_ = {-100000, -100000};
    }

    void record_corner(votv::Vec3 head, votv::Quat hq, votv::Vec3 origin, votv::Vec3 dir) {
        static const char* names[4] = {"top-left", "top-right", "bottom-right", "bottom-left"};
        auto l = votv::ray_on_plane_local(head, hq, origin, dir, s_.screen.distance);
        if (!l.ok) { log("calibration: corner %s not recorded (ray doesn't reach the plane in front); try again", names[calib_n_]); return; }
        calib_[calib_n_] = l;
        log("calibration: corner %d of 4 (%s) at x %.3f y %.3f m%s", calib_n_ + 1, names[calib_n_], l.x, l.y,
            calib_n_ < 3 ? (std::string("; next: ") + names[calib_n_ + 1]).c_str() : "");
        if (++calib_n_ < 4) return;
        calib_n_ = 0;
        auto m = votv::fit_screen(calib_, s_.screen.distance);
        if (m.width < 0.2f || m.width > 10.f || m.aspect < 0.5f || m.aspect > 4.f) {
            log("calibration: fit rejected (width %.2f m, aspect %.2f); corners again from top-left", m.width, m.aspect);
            return;
        }
        s_.screen = m;
        s_.calibrate = false;
        log("calibration: fitted width %.3f m aspect %.3f right %.3f up %.3f at %.2f m; applied, clicking %s",
            m.width, m.aspect, m.offset_right, m.offset_up, m.distance, s_.click ? "on" : "off");
        save_screen(m);
    }

    // Rewrite votv_pointer.txt with the fitted screen and ptr_calibrate=0, keeping other lines.
    void save_screen(const votv::ScreenModel& m) {
        auto p = dir_ / "scripts" / "votv_pointer.txt";
        std::ifstream in(p);
        std::stringstream out;
        std::string line;
        static const char* keys[] = {"ptr_screen_distance_m", "ptr_screen_width_m", "ptr_screen_aspect", "ptr_screen_offset_right_m",
                                     "ptr_screen_offset_up_m", "ptr_calibrate"};
        while (std::getline(in, line)) {
            bool drop = false;
            for (auto k : keys) if (line.rfind(k, 0) == 0) drop = true;
            if (!drop) out << line << "\n";
        }
        in.close();
        char buf[512];
        snprintf(buf, sizeof(buf), "ptr_screen_distance_m=%.3f\nptr_screen_width_m=%.3f\nptr_screen_aspect=%.4f\nptr_screen_offset_right_m=%.3f\nptr_screen_offset_up_m=%.3f\nptr_calibrate=0\n",
                 m.distance, m.width, m.aspect, m.offset_right, m.offset_up);
        out << "# calibrated " << buf;
        std::ofstream o(p, std::ios::trunc);
        o << out.str();
        o.close();
        std::error_code ec;
        settings_mtime_ = fs::last_write_time(p, ec);  // don't reload our own write as a change
        log("calibration: saved to %s", p.string().c_str());
    }

    void load_settings(bool first) {
        auto p = dir_ / "scripts" / "votv_pointer.txt";
        std::error_code ec;
        auto mt = fs::last_write_time(p, ec);
        auto cp = dir_ / "scripts" / "votv_controls.txt";
        auto mt2 = fs::last_write_time(cp, ec);
        if (!first && mt == settings_mtime_ && mt2 == controls_mtime_) return;
        settings_mtime_ = mt; controls_mtime_ = mt2;
        Settings n;
        auto kv = parse_kv(p);
        auto f = [&](const char* k, float& v) { auto it = kv.find(k); if (it != kv.end()) try { v = std::stof(it->second); } catch (...) {} };
        auto d = [&](const char* k, double& v) { auto it = kv.find(k); if (it != kv.end()) try { v = std::stod(it->second); } catch (...) {} };
        auto i = [&](const char* k, int& v) { auto it = kv.find(k); if (it != kv.end()) try { v = std::stoi(it->second); } catch (...) {} };
        auto b = [&](const char* k, bool& v) { auto it = kv.find(k); if (it != kv.end()) v = it->second == "1" || it->second == "true"; };
        b("ptr_enabled", n.enabled);
        f("ptr_screen_distance_m", n.screen.distance);
        f("ptr_screen_width_m", n.screen.width);
        f("ptr_screen_aspect", n.screen.aspect);
        f("ptr_screen_offset_up_m", n.screen.offset_up);
        f("ptr_screen_offset_right_m", n.screen.offset_right);
        f("ptr_trigger_on", n.trigger_on);
        f("ptr_trigger_off", n.trigger_off);
        f("ptr_wheel_threshold", n.wheel_threshold);
        d("ptr_wheel_repeat_ms", n.wheel_repeat_ms);
        i("ptr_dot_px", n.dot_px);
        b("ptr_trace_hits", n.trace_hits);
        b("ptr_dot_desktop", n.dot_desktop);
        b("ptr_calibrate", n.calibrate);
        b("ptr_dot_ui", n.dot_ui);
        b("ptr_dot_umg", n.dot_umg);
        b("ptr_dot_scene", n.dot_scene);
        b("ptr_click", n.click);
        b("ptr_dot_framework", n.dot_framework);
        f("ptr_dot_framework_scale", n.dot_framework_scale);
        auto ckv = parse_kv(cp);
        auto lh = ckv.find("ctl_left_handed");
        n.left_handed = lh != ckv.end() && (lh->second == "1" || lh->second == "true");
        if (n.calibrate && !s_.calibrate) { calib_n_ = 0; log("calibration: started; point at the screen's top-left corner and pull the trigger"); }
        s_ = n;
        log("settings: enabled=%d calibrate=%d click=%d distance=%.2f width=%.2f aspect=%.3f up=%.2f right=%.2f dot=%d left_handed=%d (%s)",
            (int)n.enabled, (int)n.calibrate, (int)n.click, n.screen.distance, n.screen.width, n.screen.aspect, n.screen.offset_up, n.screen.offset_right,
            n.dot_px, (int)n.left_handed, kv.empty() ? "defaults, no votv_pointer.txt" : "votv_pointer.txt");
    }

    void log(const char* fmt, ...) {
        char buf[1024];
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(buf, sizeof(buf), fmt, ap);
        va_end(ap);
        SYSTEMTIME st;
        GetLocalTime(&st);
        char line[1100];
        snprintf(line, sizeof(line), "[%02d:%02d:%02d.%03d] %s", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, buf);
        if (trace_) { trace_ << line << "\n"; trace_.flush(); }
        API::get()->log_info("[votv_pointer] %s", buf);
    }

    fs::path dir_;
    std::ofstream trace_;
    Settings s_;
    fs::file_time_type settings_mtime_{}, controls_mtime_{};
    double settings_t_ = 0, hit_log_t_ = 0, wheel_t_ = 0;
    UEVR_ActionHandle trigger_action_{};
    votv::Hysteresis trigger_;
    bool button_down_ = false;
    POINT last_pt_{-100000, -100000};
    POINT last_client_{0, 0};
    std::atomic<bool> dot_visible_{false};
    std::atomic<float> dot_u_{0.5f}, dot_v_{0.5f};
    bool warned_renderer_ = false;
    bool logged_framework_ = false;
    RtCache ui_rt_, scene_rt_;
    votv::Local2 calib_[4];
    int calib_n_ = 0;
    ID3D11RenderTargetView* rtv_ = nullptr;
    ID3D11Texture2D* rtv_tex_ = nullptr;
};

VotvPointer g_plugin{};

}  // namespace
