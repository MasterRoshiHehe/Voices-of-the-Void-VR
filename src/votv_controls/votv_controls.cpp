// VOTV VR controls: UEVR C++ plugin (built against UEVR's MIT-licensed plugin headers only).
//
// Reads the Touch controllers through UEVR's emulated XInput state, maps them to the game's own key
// bindings (mapper.hpp, CONTROLS.md section 2) and sends those keys with SendInput, only while the game
// window has focus. The emulated pad itself is hidden from the game (it has no gamepad bindings; the pad
// would only move UMG focus). Also sets UEVR's aim method (right controller by default) and snap turn.
//
// Files in UEVR's profile folder (persistent dir):
//   scripts\votv_controls.txt   live settings, re-read when changed (key=value, see load_settings)
//   votv_controls_trace.txt     every sent key/wheel/recentre/release with ms timestamps
//   votv_driver.txt             test driver mailbox (scripted controller states; see run_driver_file)
#include <windows.h>
#include <psapi.h>

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <sstream>

#include "uevr/Plugin.hpp"
#include "mapper.hpp"
#include "xr_hands.hpp"
#include <openvr.h>   // SteamVR skeletal input (Index per-finger curl); tools/openvr-sdk headers, loaded via UEVR's openvr_api.dll

using namespace uevr;
namespace fs = std::filesystem;

namespace {

double now_ms() {
    using namespace std::chrono;
    return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

std::string read_file(const fs::path& p) {
    std::ifstream f(p, std::ios::binary);
    if (!f) return {};
    std::stringstream ss; ss << f.rdbuf();
    std::string s = ss.str();
    // Input.ini may be UTF-16; keep only the low bytes if so.
    if (s.size() >= 2 && (unsigned char)s[0] == 0xFF && (unsigned char)s[1] == 0xFE) {
        std::string out; for (size_t i = 2; i + 1 < s.size(); i += 2) out.push_back(s[i]); return out;
    }
    return s;
}

// UE key name -> Windows virtual key (0 = unsupported). Mouse buttons handled separately.
WORD vk_for(const std::string& k) {
    if (k.size() == 1 && k[0] >= 'A' && k[0] <= 'Z') return (WORD)k[0];
    static const std::map<std::string, WORD> m = {
        {"Zero", '0'}, {"One", '1'}, {"Two", '2'}, {"Three", '3'}, {"Four", '4'}, {"Five", '5'}, {"Six", '6'},
        {"Seven", '7'}, {"Eight", '8'}, {"Nine", '9'}, {"SpaceBar", VK_SPACE}, {"LeftShift", VK_LSHIFT},
        {"RightShift", VK_RSHIFT}, {"LeftControl", VK_LCONTROL}, {"RightControl", VK_RCONTROL}, {"LeftAlt", VK_LMENU},
        {"RightAlt", VK_RMENU}, {"Tab", VK_TAB}, {"Escape", VK_ESCAPE}, {"Enter", VK_RETURN}, {"BackSpace", VK_BACK},
        {"F1", VK_F1}, {"F2", VK_F2}, {"F3", VK_F3}, {"F4", VK_F4}, {"F5", VK_F5}, {"F6", VK_F6}, {"F7", VK_F7},
        {"F8", VK_F8}, {"F9", VK_F9}, {"F10", VK_F10}, {"F11", VK_F11}, {"F12", VK_F12}, {"Up", VK_UP}, {"Down", VK_DOWN},
        {"Left", VK_LEFT}, {"Right", VK_RIGHT}, {"NumPadZero", VK_NUMPAD0}, {"Decimal", VK_DECIMAL},
    };
    auto it = m.find(k);
    return it == m.end() ? 0 : it->second;
}

class VotvControls : public Plugin {
public:
    void on_dllmain() override {
        // before UEVR creates its OpenXR instance (~2 s later): add hand tracking (xr_hands.hpp). Not under the loader lock.
        CreateThread(nullptr, 0, [](LPVOID) -> DWORD { xrh::install(); return 0; }, nullptr, 0, nullptr);
    }

    void on_initialize() override {
        dir_ = API::get()->get_persistent_dir();
        trace_.open(dir_ / "votv_controls_trace.txt", std::ios::app);
        log("start: plugin votv_controls v1, build %s %s, profile dir %s", __DATE__, __TIME__, dir_.string().c_str());
        load_bindings();
        load_settings(true);

        mapper_.sink.key = [this](const std::string& key, bool down, const std::string& why) { send_key(key, down, why); };
        mapper_.sink.wheel = [this](int n, const std::string& why) { send_wheel(n, why); };
        mapper_.sink.mouse_move = [this](float dx, float dy) { send_mouse_move(dx, dy); };
        mapper_.sink.recenter = [this]() { API::VR::recenter_view(); event("recenter"); };
        mapper_.sink.layer_changed = [this](bool on) {
            layer_on_ = on;
            if (snap_turn_) API::VR::set_mod_value("VR_SnapTurn", !on);
            event(on ? "layer on" : "layer off");
        };
    }

    void on_xinput_get_state(uint32_t* retval, uint32_t user_index, XINPUT_STATE* state) override {
        if (retval == nullptr || state == nullptr || *retval != ERROR_SUCCESS) return;
        {
            std::scoped_lock lk(pad_mtx_);
            const auto& g = state->Gamepad;
            pad_.buttons = g.wButtons;
            pad_.lt = g.bLeftTrigger / 255.f; pad_.rt = g.bRightTrigger / 255.f;
            auto ax = [](SHORT v) { return std::clamp(v / 32767.f, -1.f, 1.f); };
            pad_.lx = ax(g.sThumbLX); pad_.ly = ax(g.sThumbLY); pad_.rx = ax(g.sThumbRX); pad_.ry = ax(g.sThumbRY);
            pad_t_ = now_ms();
        }
        if (!seen_pad_) { seen_pad_ = true; log("xinput: first controller state (user %u)", user_index); }
        if (zero_pad_) { auto pkt = state->dwPacketNumber; ZeroMemory(&state->Gamepad, sizeof(state->Gamepad)); state->dwPacketNumber = pkt; }
    }

    void on_pre_engine_tick(API::UGameEngine*, float) override {
        const double t = now_ms();
        if (t - settings_check_t_ > 1000) { settings_check_t_ = t; load_settings(false); poll_driver_file(); }

        if (t - uevr_check_t_ > 1000) { uevr_check_t_ = t; enforce_uevr_values(); }
        if (t - cfg_sent_t_ > 2000) { cfg_sent_t_ = t; API::get()->dispatch_lua_event("votv_cfg", settings_text_.c_str());
            if (presets_t_ == 0) load_presets(); else API::get()->dispatch_lua_event("votv_presets", presets_text().c_str()); presets_t_ = t; }
        if (t - settings_check_t_ < 50) poll_preset_saves();

        votv::PadState p;
        double pad_t;
        { std::scoped_lock lk(pad_mtx_); p = pad_; pad_t = pad_t_; }
        trace_right_stick(p);
        const bool driving = driver_active(t, p);
        if (driving) pad_t = t;

        std::string block;
        if (!mapper_.s.enabled) block = "disabled";
        else if (!game_has_focus()) block = "focus";
        else if (!driving && !API::VR::is_hmd_active()) block = "hmd";
        else if (t - pad_t > 500) block = "no_pad";
        if (!block.empty()) {
            if (block != blocked_) { mapper_.release_all(block); event("blocked: " + block); blocked_ = block; }
            return;
        }
        if (!blocked_.empty()) { event("unblocked (was " + blocked_ + ")"); blocked_.clear(); }
        mask_for_pointer(p);
        mapper_.update(p, t);
        smooth_turn(p, t);
        update_fingers(p, t);
    }

    // Menu laser pointer (main-menu thread's votv_pointer.dll) owns the pointing hand's trigger, stick and A
    // while a flat menu is shown. Those inputs stay masked here until physically released after it lets go.
    bool pointer_active() {
        HMODULE m = GetModuleHandleW(L"votv_pointer.dll");
        if (m == nullptr) return false;
        using Fn = bool (*)();
        auto fn = (Fn)GetProcAddress(m, "votv_pointer_active");
        return fn != nullptr && fn();
    }
    void mask_for_pointer(votv::PadState& p) {
        const bool lh = mapper_.s.left_handed;
        float& trig = lh ? p.lt : p.rt;
        float& sx = lh ? p.lx : p.rx;
        float& sy = lh ? p.ly : p.ry;
        const uint16_t btn = lh ? votv::PAD_X : votv::PAD_A;
        const bool on = pointer_active();
        if (on != pointer_on_) { pointer_on_ = on; event(on ? "pointer active: trigger/stick/A masked" : "pointer inactive"); }
        if (on) { mask_trig_ = mask_stick_ = mask_btn_ = true; }
        else {
            if (mask_trig_ && trig < mapper_.s.trigger_release) mask_trig_ = false;
            if (mask_stick_ && std::fabs(sx) < turn_deadzone_ && std::fabs(sy) < turn_deadzone_) mask_stick_ = false;
            if (mask_btn_ && !(p.buttons & btn)) mask_btn_ = false;
        }
        if (mask_trig_) trig = 0;
        if (mask_stick_) { sx = 0; sy = 0; }
        if (mask_btn_) p.buttons &= ~btn;
    }

    // Smooth turn (default; user 2026-11-27: "I hate snap turning"): right stick X outside the grip layer turns
    // the player at up to ctl_turn_speed deg/s. Method 0: the game's own AddControllerYawInput on the pawn
    // (Val * InputYawScale degrees, scale assumed 2.5, setting ctl_yaw_scale); method 1: UEVR's VR rotation offset.
    void smooth_turn(const votv::PadState& p, double t) {
        const double dt = turn_t_ > 0 ? std::min(100.0, t - turn_t_) / 1000.0 : 0.0;
        turn_t_ = t;
        if (snap_turn_ || layer_on_ || dt <= 0) return;
        const float dz = turn_deadzone_, ax = std::fabs(p.rx);
        if (ax <= dz) { if (turning_) { turning_ = false; event("smooth turn stop"); } return; }
        const float k = (ax - dz) / (1.f - dz);
        const float deg = (p.rx > 0 ? 1.f : -1.f) * k * k * turn_speed_ * (float)dt;   // squared curve: fine control near centre
        if (!turning_) { turning_ = true; event("smooth turn start (method " + std::to_string(turn_method_) + ")"); }
        if (turn_method_ == 0) {
            auto pawn = API::get()->get_local_pawn(0);
            if (pawn == nullptr) return;
            struct { float Val; } params{deg / yaw_scale_};
            pawn->call_function(L"AddControllerYawInput", &params);
        } else {
            UEVR_Quaternionf q{};
            API::get()->param()->vr->get_rotation_offset(&q);
            const float h = -deg * 3.14159265f / 360.f;   // half angle, yaw about the up axis (Y in UEVR's space)
            const float c = std::cos(h), s = std::sin(h);
            UEVR_Quaternionf r{q.w * c - q.y * s, q.x * c - q.z * s, q.w * s + q.y * c, q.x * s + q.z * c};   // q * yaw(h)
            API::get()->param()->vr->set_rotation_offset(&r);
        }
    }

private:
    fs::path dir_;
    std::ofstream trace_;
    std::mutex pad_mtx_;
    votv::PadState pad_{};
    double pad_t_{0}, settings_check_t_{0}, uevr_check_t_{0}, cfg_sent_t_{0};
    std::string settings_text_;   // forwarded to the Lua scripts (no file access in UEVR 1.05 Lua)
    bool layer_on_{false}, turning_{false};
    bool pointer_on_{false}, mask_trig_{false}, mask_stick_{false}, mask_btn_{false};
    double turn_t_{0};
    float turn_speed_{120}, turn_deadzone_{0.2f}, yaw_scale_{2.5f};
    int turn_method_{0};
    float finger_speed_{14}, thumb_rest_{0.6f};
    xrh::Tracker xr_;
    int hand_tracking_{1};
    UEVR_ActionHandle touch_h_[2][3]{};
    const char* touch_right_[3]{"/actions/default/in/AButtonTouchRight", "/actions/default/in/BButtonTouchRight", "/actions/default/in/ThumbrestTouchRight"};
    const char* touch_left_[3]{"/actions/default/in/AButtonTouchLeft", "/actions/default/in/BButtonTouchLeft", "/actions/default/in/ThumbrestTouchLeft"};
    int rstick_x_state_{0};
    votv::Mapper mapper_;
    bool seen_pad_{false}, zero_pad_{true}, snap_turn_{true};
    int aim_method_{-1};
    std::string blocked_{"start"};
    fs::file_time_type settings_mtime_{};
    float mouse_acc_x_{0}, mouse_acc_y_{0};

    // Test driver: keyframes (ms from start -> full pad state), replacing the real controllers.
    struct Frame { double ms; votv::PadState p; };
    std::vector<Frame> drv_;
    double drv_start_{0};
    std::string drv_id_;

    template <typename... A> void log(const char* fmt, A... a) {
        std::string f = std::string("[votv-ctl] ") + fmt;
        API::get()->log_info(f.c_str(), a...);
    }
    void event(const std::string& what) {
        char buf[64]; snprintf(buf, sizeof(buf), "%.0f ", now_ms());
        if (trace_) { trace_ << buf << what << "\n"; trace_.flush(); }
        log("%s", what.c_str());
        API::get()->dispatch_lua_event("votv_ctl", what.c_str());
    }

    bool game_has_focus() {
        HWND fg = GetForegroundWindow();
        DWORD pid = 0; GetWindowThreadProcessId(fg, &pid);
        return fg != nullptr && pid == GetCurrentProcessId();
    }

    void load_bindings() {
        char* la = nullptr; size_t n = 0;
        _dupenv_s(&la, &n, "LOCALAPPDATA");
        fs::path ini = fs::path(la ? la : "") / "VotV" / "Saved" / "Config" / "WindowsNoEditor" / "Input.ini";
        free(la);
        auto b = votv::parse_input_ini(read_file(ini));
        // Only actions the layout uses; anything missing keeps the game's default key.
        int from_ini = 0;
        for (auto& [action, key] : mapper_.bindings) {
            auto it = b.find(action);
            if (it != b.end()) { key = it->second; ++from_ini; }
        }
        std::string list;
        for (auto& [a, k] : mapper_.bindings) list += a + "=" + k + " ";
        log("bindings: %d of %d from %s; %s", from_ini, (int)mapper_.bindings.size(), ini.string().c_str(), list.c_str());
    }

    void load_settings(bool first) {
        fs::path p = dir_ / "scripts" / "votv_controls.txt";
        std::error_code ec;
        auto mt = fs::last_write_time(p, ec);
        if (!first && (ec || mt == settings_mtime_)) return;
        settings_mtime_ = mt;
        std::string text = read_file(p);
        settings_text_ = text;
        cfg_sent_t_ = 0;
        auto num = [&](const char* key, float def) {
            auto pos = text.find(std::string(key) + "=");
            return pos == std::string::npos ? def : (float)atof(text.c_str() + pos + strlen(key) + 1);
        };
        auto& s = mapper_.s;
        bool was_enabled = s.enabled;
        s.enabled = num("ctl_enabled", 1) != 0;
        s.left_handed = num("ctl_left_handed", 0) != 0;
        s.trigger_press = num("ctl_trigger_press", s.trigger_press);
        s.trigger_release = num("ctl_trigger_release", s.trigger_release);
        s.move_threshold = num("ctl_move_threshold", s.move_threshold);
        s.stick_centre = num("ctl_stick_centre", s.stick_centre);
        s.wheel_threshold = num("ctl_wheel_threshold", s.wheel_threshold);
        s.wheel_repeat_ms = num("ctl_wheel_repeat_ms", s.wheel_repeat_ms);
        s.rotate_threshold = num("ctl_rotate_threshold", s.rotate_threshold);
        s.rotate_speed = num("ctl_rotate_speed", s.rotate_speed);
        s.menu_hold_ms = num("ctl_menu_hold_ms", s.menu_hold_ms);
        s.run_latch = num("ctl_run_latch", 1) != 0;
        zero_pad_ = num("ctl_zero_pad", 1) != 0;
        snap_turn_ = num("ctl_snap_turn", 0) != 0;     // 0 = smooth turn (default), 1 = UEVR snap turn
        turn_speed_ = num("ctl_turn_speed", turn_speed_);
        turn_deadzone_ = std::clamp(num("ctl_turn_deadzone", turn_deadzone_), 0.f, 0.9f);
        yaw_scale_ = std::max(0.01f, num("ctl_yaw_scale", yaw_scale_));
        turn_method_ = (int)num("ctl_turn_method", 0);
        finger_speed_ = num("ctl_finger_speed", 14);
        thumb_rest_ = num("ctl_thumb_rest", 0.6f);
        hand_tracking_ = (int)num("ctl_hand_tracking", 1);
        int aim = (int)num("ctl_aim_method", 1);   // UEVR enum: 0 game, 1 head, 2 right controller, 3 left; hand ray: votv_hand_aim.lua
        if (s.left_handed && aim == 2) aim = 3;
        if (aim >= 0 && aim <= 5) aim_method_ = aim;
        // Applied (and re-applied) by enforce_uevr_values: UEVR loads the profile config *after* plugins
        // initialise, which overwrote these on the 01:40 run (aim stayed 0, snap turn off).
        uevr_check_t_ = 0;
        if (was_enabled && !s.enabled) mapper_.release_all("disabled");
        log("settings %s (%s): enabled=%d left_handed=%d aim=%d snap=%d zero_pad=%d trig=%.2f/%.2f move=%.2f",
            first ? "loaded" : "reloaded", text.empty() ? "file missing, defaults" : "file", s.enabled, s.left_handed,
            aim_method_, snap_turn_, zero_pad_, s.trigger_press, s.trigger_release, s.move_threshold);
    }


    // ---- finger curl for the VR hands (votv_hands.lua) ----
    // User 2026-11-27 18:30: grip curls middle/ring/pinky, trigger the index finger, face buttons the thumb; Valve
    // Index (Knuckles) must drive all five fingers. Source per run: SteamVR skeletal summary (UEVR's manifest has
    // /actions/default/in/Skeleton{Left,Right}Hand) when UEVR runs on OpenVR and the device reports it, else the
    // buttons (UEVR's emulated XInput: analog triggers, digital grips/face buttons). Curls are 0..1 per finger
    // (thumb, index, middle, ring, pinky), smoothed, and sent to Lua as "votv_fingers" events (max 60 Hz).
    vr::IVRInput* vrin_{nullptr};
    vr::VRActionHandle_t skel_[2]{0, 0};
    bool vr_tried_{false};
    std::string finger_src_;
    float curl_[2][5]{}, curl_sent_[2][5]{};
    double finger_t_{0}, finger_sent_t_{0};

    bool skeletal(int side, float out[5]) {
        if (!vr_tried_) {
            vr_tried_ = true;
            if (API::VR::is_openvr()) {
                HMODULE m = GetModuleHandleW(L"openvr_api.dll");
                using Fn = void* (*)(const char*, vr::EVRInitError*);
                auto fn = m ? (Fn)GetProcAddress(m, "VR_GetGenericInterface") : nullptr;
                vr::EVRInitError err = vr::VRInitError_None;
                if (fn) vrin_ = (vr::IVRInput*)fn(vr::IVRInput_Version, &err);
                if (vrin_) {
                    vrin_->GetActionHandle("/actions/default/in/SkeletonLeftHand", &skel_[0]);
                    vrin_->GetActionHandle("/actions/default/in/SkeletonRightHand", &skel_[1]);
                }
                event(std::string("fingers: SteamVR input ") + (vrin_ ? "found" : "not available"));
            }
        }
        if (vrin_ == nullptr || skel_[side] == 0) return false;
        vr::VRSkeletalSummaryData_t d{};
        if (vrin_->GetSkeletalSummaryData(skel_[side], vr::VRSummaryType_FromDevice, &d) != vr::VRInputError_None) return false;
        for (int f = 0; f < 5; ++f) out[f] = std::clamp(d.flFingerCurl[f], 0.f, 1.f);
        return true;
    }

    void update_fingers(const votv::PadState& p, double t) {
        const double dt = finger_t_ > 0 ? std::min(100.0, t - finger_t_) / 1000.0 : 0.0;
        finger_t_ = t;
        for (int side = 0; side < 2; ++side) {
            float target[5];
            std::string src = "openxr hand tracking";
            bool got = false;
            if (API::VR::is_openxr() && hand_tracking_ != 0) {
                auto* ox = API::get()->param()->openxr;
                if (!xr_.tried && ox->get_xr_session() != nullptr) {
                    if (!xrh::g_log.empty()) event("fingers: " + xrh::g_log);
                    {   // which openxr_loader modules are loaded (a second copy would bypass the hook)
                        std::string mods;
                        HMODULE hm[1024]; DWORD need = 0;
                        if (K32EnumProcessModules(GetCurrentProcess(), hm, sizeof(hm), &need))
                            for (DWORD i = 0; i < need / sizeof(HMODULE); ++i) {
                                char path[MAX_PATH]{}; GetModuleFileNameA(hm[i], path, MAX_PATH);
                                if (std::strstr(path, "openxr_loader") || std::strstr(path, "OPENXR_LOADER")) mods += std::string(path) + " ";
                            }
                        event("fingers: loaded openxr_loader modules: " + mods);
                    }
                    xr_.init((XrInstance)ox->get_xr_instance(), (XrSession)ox->get_xr_session());
                    event("fingers: " + xr_.status);
                }
                if (xr_.ok) got = xr_.curls((XrSpace)ox->get_stage_space(), side, target);
            }
            if (!got) src = "skeletal";
            if (!got && !skeletal(side, target)) {
                src = "buttons";
                const bool right = side == 1;
                const float trig = right ? p.rt : p.lt;
                const bool grip = (p.buttons & (right ? votv::PAD_RSHOULDER : votv::PAD_LSHOULDER)) != 0;
                const bool thumb = (p.buttons & (right ? (votv::PAD_A | votv::PAD_B | votv::PAD_RTHUMB)
                                                       : (votv::PAD_X | votv::PAD_Y | votv::PAD_LTHUMB))) != 0;
                // Touch states (UEVR OpenXR actions, research doc): a thumb resting on A/B (X/Y) or the thumbrest
                // lowers the thumb part-way; a press closes it; lifted = thumb up.
                bool rest = false;
                if (touch_h_[0][0] == 0) for (int s3 = 0; s3 < 2; ++s3) for (int a = 0; a < 3; ++a)
                    touch_h_[s3][a] = API::VR::get_action_handle(s3 == 1 ? touch_right_[a] : touch_left_[a]);
                const auto src = right ? API::VR::get_right_joystick_source() : API::VR::get_left_joystick_source();
                for (int a = 0; a < 3; ++a) if (touch_h_[side][a] != 0 && API::VR::is_action_active(touch_h_[side][a], src)) rest = true;
                // Pose presets per button state (user 19:19: "save presets for the different button presses").
                // Base pose: open -> trigger (blended by how far the trigger is pulled), or grip -> fist with the
                // grip held; the thumb comes from the "thumb rest" / "thumb press" preset when touched / pressed.
                const float tv = std::clamp(trig, 0.f, 1.f);
                const float* a = presets_[grip ? P_GRIP : P_OPEN];
                const float* b = presets_[grip ? P_FIST : P_TRIGGER];
                for (int f = 0; f < 5; ++f) target[f] = a[f] + (b[f] - a[f]) * tv;
                if (thumb) target[0] = presets_[P_THUMB_PRESS][0];
                else if (rest) target[0] = presets_[P_THUMB_REST][0];
            }
            if (side == 1 && src != finger_src_) { finger_src_ = src; event("fingers: source " + src); }
            // close faster than open (research doc: smoothing ~15-25 Hz, closing quicker feels right)
            for (int f = 0; f < 5; ++f) {
                const float rate = target[f] > curl_[side][f] ? finger_speed_ * 1.5f : finger_speed_;
                curl_[side][f] += (target[f] - curl_[side][f]) * (float)std::min(1.0, dt * rate);
            }
        }
        bool changed = false;
        for (int s2 = 0; s2 < 2; ++s2) for (int f = 0; f < 5; ++f) if (std::fabs(curl_[s2][f] - curl_sent_[s2][f]) > 0.01f) changed = true;
        if (!changed || t - finger_sent_t_ < 16) return;
        finger_sent_t_ = t;
        char buf[160];
        snprintf(buf, sizeof(buf), "L %.2f %.2f %.2f %.2f %.2f R %.2f %.2f %.2f %.2f %.2f",
                 curl_[0][0], curl_[0][1], curl_[0][2], curl_[0][3], curl_[0][4], curl_[1][0], curl_[1][1], curl_[1][2], curl_[1][3], curl_[1][4]);
        std::memcpy(curl_sent_, curl_, sizeof(curl_));
        API::get()->dispatch_lua_event("votv_fingers", buf);
    }


    // ---- hand pose presets (votv_hand_presets.txt in the profile folder; edited from the Lua debug panel) ----
    enum { P_OPEN, P_TRIGGER, P_GRIP, P_FIST, P_THUMB_REST, P_THUMB_PRESS, P_COUNT };
    static constexpr const char* preset_names_[P_COUNT]{"open", "trigger", "grip", "fist", "thumb_rest", "thumb_press"};
    float presets_[P_COUNT][5]{
        {0.10f, 0.10f, 0.10f, 0.10f, 0.10f}, {0.10f, 0.85f, 0.10f, 0.10f, 0.10f}, {0.20f, 0.10f, 0.90f, 0.90f, 0.90f},
        {0.60f, 0.90f, 0.90f, 0.90f, 0.90f}, {0.50f, 0.f, 0.f, 0.f, 0.f}, {0.90f, 0.f, 0.f, 0.f, 0.f}};
    std::streamoff log_pos_{-1};
    double presets_t_{0};

    std::string presets_text() {
        std::string t;
        for (int i = 0; i < P_COUNT; ++i) {
            char b[160]; snprintf(b, sizeof(b), "%s=%.2f %.2f %.2f %.2f %.2f\n", preset_names_[i],
                                  presets_[i][0], presets_[i][1], presets_[i][2], presets_[i][3], presets_[i][4]);
            t += b;
        }
        return t;
    }
    void parse_presets(const std::string& text) {
        for (int i = 0; i < P_COUNT; ++i) {
            auto k = text.find(std::string(preset_names_[i]) + "=");
            if (k == std::string::npos) continue;
            float v[5]; int n = sscanf_s(text.c_str() + k + strlen(preset_names_[i]) + 1, "%f %f %f %f %f", &v[0], &v[1], &v[2], &v[3], &v[4]);
            if (n == 5) for (int f = 0; f < 5; ++f) presets_[i][f] = std::clamp(v[f], 0.f, 1.f);
        }
    }
    void load_presets() {
        std::string t = read_file(dir_ / "votv_hand_presets.txt");
        if (!t.empty()) parse_presets(t);
        event(std::string("fingers: presets ") + (t.empty() ? "default" : "loaded from votv_hand_presets.txt"));
        API::get()->dispatch_lua_event("votv_presets", presets_text().c_str());
    }
    // The Lua panel can't write files, so it logs "PRESETS SAVE <text>"; read new UEVR log lines every second.
    void poll_preset_saves() {
        std::ifstream f(dir_ / "log.txt", std::ios::binary);
        if (!f) return;
        f.seekg(0, std::ios::end);
        std::streamoff end = f.tellg();
        if (log_pos_ < 0 || end < log_pos_) { log_pos_ = end; return; }
        if (end == log_pos_) return;
        f.seekg(log_pos_);
        std::string chunk((size_t)(end - log_pos_), '\0');
        f.read(chunk.data(), chunk.size());
        log_pos_ = end;
        auto k = chunk.rfind("PRESETS SAVE ");
        if (k == std::string::npos) return;
        std::string line = chunk.substr(k + 13, chunk.find('\n', k) - k - 13);
        for (auto& c : line) if (c == ';') c = '\n';
        parse_presets(line);
        std::ofstream o(dir_ / "votv_hand_presets.txt", std::ios::binary | std::ios::trunc);
        o << presets_text();
        event("fingers: presets saved to votv_hand_presets.txt");
        API::get()->dispatch_lua_event("votv_presets", presets_text().c_str());
    }

    // UEVR mod values this plugin owns. Checked every second; re-set and logged when they differ (profile
    // config load, UEVR menu). The settings file is the source of truth.
    void enforce_uevr_values() {
        // Flat 2D main menu: votv_menu_camera.lua pins the screen (forces aim 0, snap off) and restores the
        // saved values when the menu is left, so don't fight it here (menu-laser thread, 2026-11-27).
        bool twod = false;
        try { twod = API::VR::get_mod_value<bool>("VR_2DScreenMode"); } catch (...) {}
        if (twod) return;
        const std::string want_aim = std::to_string(aim_method_);
        const bool want_snap = snap_turn_ && !layer_on_;
        const std::string aim_now = API::VR::get_mod_value<std::string>("VR_AimMethod");
        const bool snap_now = API::VR::get_mod_value<bool>("VR_SnapTurn");
        if (aim_now != want_aim || (int)API::VR::get_aim_method() != aim_method_) {
            API::get()->param()->vr->set_mod_value("VR_AimMethod", want_aim.c_str());
            API::VR::set_aim_method((API::VR::AimMethod)aim_method_);
            event("uevr: VR_AimMethod was " + aim_now + ", set " + want_aim + " (now " +
                  API::VR::get_mod_value<std::string>("VR_AimMethod") + ")");
        }
        if (snap_now != want_snap) {
            API::VR::set_mod_value("VR_SnapTurn", want_snap);
            event(std::string("uevr: VR_SnapTurn was ") + (snap_now ? "true" : "false") + ", set " +
                  (want_snap ? "true" : "false") + " (now " +
                  (API::VR::get_mod_value<bool>("VR_SnapTurn") ? "true" : "false") + ")");
        }
    }

    // Right stick X in the trace (pushed left/right/centre), to line turning reports up with the stick.
    void trace_right_stick(const votv::PadState& p) {
        int st = p.rx > 0.5f ? 1 : (p.rx < -0.5f ? -1 : 0);
        if (std::fabs(p.rx) < 0.3f) st = 0; else if (st == 0) return;   // hysteresis
        if (st != rstick_x_state_) {
            rstick_x_state_ = st;
            event(st == 0 ? "r_stick x centre" : (st > 0 ? "r_stick x right" : "r_stick x left"));
        }
    }

    // ---- output ----
    void send_key(const std::string& key, bool down, const std::string& why) {
        INPUT in{};
        if (key == "LeftMouseButton" || key == "RightMouseButton" || key == "MiddleMouseButton") {
            in.type = INPUT_MOUSE;
            in.mi.dwFlags = key[0] == 'L' ? (down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP)
                          : key[0] == 'R' ? (down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP)
                                          : (down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP);
        } else if (key == "MouseScrollUp" || key == "MouseScrollDown") {
            if (down) send_wheel(key == "MouseScrollUp" ? 1 : -1, why);
            return;
        } else {
            WORD vk = vk_for(key);
            if (vk == 0) { event("unsupported key " + key + " (" + why + ")"); return; }
            in.type = INPUT_KEYBOARD;
            in.ki.wScan = (WORD)MapVirtualKeyW(vk, MAPVK_VK_TO_VSC);
            in.ki.dwFlags = KEYEVENTF_SCANCODE | (down ? 0 : KEYEVENTF_KEYUP);
            if (vk == VK_RMENU || vk == VK_RCONTROL || (vk >= VK_LEFT && vk <= VK_DOWN)) in.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
        }
        UINT sent = SendInput(1, &in, sizeof(in));
        event(std::string(down ? "down " : "up ") + key + " (" + why + ")" + (sent == 1 ? "" : " SENDINPUT FAILED"));
    }
    void send_wheel(int notches, const std::string& why) {
        INPUT in{}; in.type = INPUT_MOUSE; in.mi.dwFlags = MOUSEEVENTF_WHEEL; in.mi.mouseData = (DWORD)(notches * WHEEL_DELTA);
        UINT sent = SendInput(1, &in, sizeof(in));
        event(std::string("wheel ") + std::to_string(notches) + " (" + why + ")" + (sent == 1 ? "" : " SENDINPUT FAILED"));
    }
    void send_mouse_move(float dx, float dy) {
        mouse_acc_x_ += dx; mouse_acc_y_ += dy;
        LONG ix = (LONG)mouse_acc_x_, iy = (LONG)mouse_acc_y_;
        if (ix == 0 && iy == 0) return;
        mouse_acc_x_ -= ix; mouse_acc_y_ -= iy;
        INPUT in{}; in.type = INPUT_MOUSE; in.mi.dwFlags = MOUSEEVENTF_MOVE; in.mi.dx = ix; in.mi.dy = iy;
        SendInput(1, &in, sizeof(in));
    }

    // ---- test driver ----
    // votv_driver.txt: first line "id <name>", then one keyframe per line:
    //   <ms> [a b x y r_grip l_grip r_thumb l_thumb menu] [rt=0..1] [lt=] [lx=-1..1] [ly=] [rx=] [ry=]
    // Each keyframe holds until the next; the last should be neutral. The file is renamed to
    // votv_driver.<id>.done when picked up, so a request never replays.
    void poll_driver_file() {
        fs::path p = dir_ / "votv_driver.txt";
        std::error_code ec;
        if (!fs::exists(p, ec) || !drv_.empty()) return;
        std::istringstream in(read_file(p));
        std::string line, id = "unnamed";
        std::vector<Frame> frames;
        while (std::getline(in, line)) {
            std::istringstream ls(line);
            std::string tok; if (!(ls >> tok)) continue;
            if (tok == "id") { ls >> id; continue; }
            if (tok[0] == '#') continue;
            Frame f{atof(tok.c_str()), {}};
            while (ls >> tok) {
                auto eq = tok.find('=');
                if (eq != std::string::npos) {
                    float v = (float)atof(tok.c_str() + eq + 1); auto k = tok.substr(0, eq);
                    if (k == "rt") f.p.rt = v; else if (k == "lt") f.p.lt = v; else if (k == "lx") f.p.lx = v;
                    else if (k == "ly") f.p.ly = v; else if (k == "rx") f.p.rx = v; else if (k == "ry") f.p.ry = v;
                    else { event("driver: rejected unknown axis " + k); return; }
                    continue;
                }
                static const std::map<std::string, uint16_t> bits = {
                    {"a", votv::PAD_A}, {"b", votv::PAD_B}, {"x", votv::PAD_X}, {"y", votv::PAD_Y},
                    {"r_grip", votv::PAD_RSHOULDER}, {"l_grip", votv::PAD_LSHOULDER}, {"r_thumb", votv::PAD_RTHUMB},
                    {"l_thumb", votv::PAD_LTHUMB}, {"menu", votv::PAD_START}};
                auto it = bits.find(tok);
                if (it == bits.end()) { event("driver: rejected unknown button " + tok); return; }
                f.p.buttons |= it->second;
            }
            frames.push_back(f);
        }
        fs::rename(p, dir_ / ("votv_driver." + id + ".done"), ec);
        if (frames.empty()) { event("driver: empty scenario " + id); return; }
        drv_ = frames; drv_id_ = id; drv_start_ = now_ms();
        mapper_.release_all("driver start");
        event("driver: start " + id + " (" + std::to_string(frames.size()) + " frames)");
    }
    bool driver_active(double t, votv::PadState& p) {
        if (drv_.empty()) return false;
        const double e = t - drv_start_;
        if (e > drv_.back().ms) {
            mapper_.release_all("driver end"); event("driver: end " + drv_id_); drv_.clear();
            return false;
        }
        for (auto& f : drv_) if (f.ms <= e) p = f.p;
        return true;
    }
};

VotvControls g_plugin{};

}  // namespace
