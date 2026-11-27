// VOTV VR: controller -> game key mapping (pure logic, no Windows calls, unit-testable).
//
// Input: one controller sample per update (UEVR's emulated XInput state from the Touch controllers).
// Output: key/mouse events through a Sink, by *game action name* resolved to the key the game has bound
// (read from the game's Input.ini), so every context (on foot, ATV) behaves exactly as on the keyboard.
// Layout: CONTROLS.md section 2. Every threshold/time is a live setting (Settings).
#pragma once

#include <array>
#include <cmath>
#include <cstdint>
#include <functional>
#include <map>
#include <string>
#include <vector>

namespace votv {

// XInput button bits (same values as Xinput.h, repeated so this header needs no Windows headers).
enum : uint16_t {
    PAD_DPAD_UP = 0x0001, PAD_DPAD_DOWN = 0x0002, PAD_DPAD_LEFT = 0x0004, PAD_DPAD_RIGHT = 0x0008,
    PAD_START = 0x0010, PAD_BACK = 0x0020, PAD_LTHUMB = 0x0040, PAD_RTHUMB = 0x0080,
    PAD_LSHOULDER = 0x0100, PAD_RSHOULDER = 0x0200, PAD_A = 0x1000, PAD_B = 0x2000, PAD_X = 0x4000, PAD_Y = 0x8000,
};

struct PadState {
    uint16_t buttons{0};
    float lt{0}, rt{0};            // 0..1
    float lx{0}, ly{0}, rx{0}, ry{0}; // -1..1, +y = up
};

struct Settings {
    bool enabled{true};
    bool left_handed{false};       // swap hands (sticks, triggers, grips, face buttons by position)
    float trigger_press{0.55f}, trigger_release{0.35f};
    float move_threshold{0.5f};    // left stick component needed for W/A/S/D
    float stick_centre{0.25f};     // below this the stick counts as centred (run latch release)
    float wheel_threshold{0.7f};   // right stick Y for a wheel notch
    float wheel_repeat_ms{250};
    float rotate_threshold{0.2f};  // right stick in the grip layer before rotate starts
    float rotate_speed{900};       // mouse counts per second at full right-stick deflection
    float menu_hold_ms{1000};      // menu button held this long = recentre instead of Esc
    bool run_latch{true};          // stick click = Shift held until the stick returns to centre
};

// What the mapper asks for. Keys are the game's key names (Input.ini spelling: "E", "LeftMouseButton").
struct Sink {
    std::function<void(const std::string& key, bool down, const std::string& why)> key;
    std::function<void(int notches, const std::string& why)> wheel;
    std::function<void(float dx, float dy)> mouse_move;
    std::function<void()> recenter;
    std::function<void(bool layer_on)> layer_changed;   // e.g. pause UEVR snap turn while the layer is held
};

// Game action -> key name, from Input.ini ActionMappings (first mapping per action wins).
using Bindings = std::map<std::string, std::string>;   // keys lowercased action names

inline std::string lower(std::string s) { for (auto& c : s) c = (char)std::tolower((unsigned char)c); return s; }

inline Bindings parse_input_ini(const std::string& text) {
    Bindings b;
    size_t pos = 0;
    while ((pos = text.find("ActionMappings=(", pos)) != std::string::npos) {
        size_t end = text.find(')', pos);
        if (end == std::string::npos) break;
        std::string entry = text.substr(pos, end - pos);
        auto field = [&](const char* name) -> std::string {
            std::string tag = std::string(name) + "=";
            size_t p = entry.find(tag);
            if (p == std::string::npos) return {};
            p += tag.size();
            size_t q = entry.find_first_of(",)", p);
            std::string v = entry.substr(p, q == std::string::npos ? std::string::npos : q - p);
            if (!v.empty() && v.front() == '"') v = v.substr(1, v.size() - 2);
            return v;
        };
        std::string action = lower(field("ActionName")), key = field("Key");
        bool modified = field("bShift") == "True" || field("bCtrl") == "True" || field("bAlt") == "True";
        if (!action.empty() && !key.empty() && key != "None" && !modified && !b.count(action)) b[action] = key;
        pos = end;
    }
    return b;
}

// Keyboard defaults (the game's own defaults, CONTROLS.md section 1) for when Input.ini can't be read.
inline Bindings default_bindings() {
    return {
        {"forward", "W"}, {"back", "S"}, {"left", "A"}, {"right", "D"}, {"run", "LeftShift"}, {"crouch", "LeftControl"},
        {"jump", "SpaceBar"}, {"use", "E"}, {"fire", "LeftMouseButton"}, {"rotate", "RightMouseButton"},
        {"lockobject", "MiddleMouseButton"}, {"drop", "R"}, {"offhand", "T"}, {"activateequipment", "LeftAlt"},
        {"inventory", "Tab"}, {"flashlight", "F"}, {"highlightnearby", "G"}, {"zoom", "X"}, {"pause", "Escape"},
        {"scrollup", "MouseScrollUp"}, {"scrolldown", "MouseScrollDown"},
    };
}

class Mapper {
public:
    Settings s;
    Bindings bindings = default_bindings();
    Sink sink;

    // Feed one sample. t_ms: monotonic milliseconds.
    void update(PadState p, double t_ms) {
        if (!s.enabled) { release_all("disabled"); last_ = PadState{}; return; }
        if (s.left_handed) p = swap_hands(p);
        const bool layer = (p.buttons & PAD_LSHOULDER) != 0;
        if (layer != layer_) { layer_ = layer; if (sink.layer_changed) sink.layer_changed(layer); }

        // Digital buttons: the action chosen at press time is the one released, even if the layer changed.
        button(PAD_RSHOULDER, p, "use", "use");
        button(PAD_RTHUMB, p, "flashlight", "mark");   // layer + stick click = mark (votv_marks.dll); "mark" has no key, so nothing is sent
        button(PAD_X, p, "crouch", "highlightnearby");
        button(PAD_Y, p, "inventory", "zoom");
        button(PAD_A, p, "jump", "lockobject");
        button(PAD_B, p, "drop", "offhand");
        analog_trigger(rt_down_, p.rt, "fire", "r_trigger");
        analog_trigger(lt_down_, p.lt, "activateequipment", "l_trigger");

        // Movement: left stick to the four digital move actions.
        hold_action(fwd_, p.ly > s.move_threshold, "forward", "l_stick");
        hold_action(back_, p.ly < -s.move_threshold, "back", "l_stick");
        hold_action(left_, p.lx < -s.move_threshold, "left", "l_stick");
        hold_action(right_, p.lx > s.move_threshold, "right", "l_stick");

        // Run: stick click; latched until the stick returns to centre (or while the click is held).
        const bool click = (p.buttons & PAD_LTHUMB) != 0;
        const float lmag = std::sqrt(p.lx * p.lx + p.ly * p.ly);
        if (click && !(last_.buttons & PAD_LTHUMB)) run_latched_ = true;
        if (!s.run_latch) run_latched_ = click;
        else if (!click && lmag < s.stick_centre) run_latched_ = false;
        hold_action(run_, run_latched_, "run", "l_thumb");

        // Right stick: wheel notches outside the layer; rotate (RMB + mouse) inside it. X is UEVR's snap turn.
        const bool rotating = layer && (std::fabs(p.rx) > s.rotate_threshold || std::fabs(p.ry) > s.rotate_threshold);
        hold_action(rotate_, rotating, "rotate", "layer+r_stick");
        if (rotating && last_t_ > 0 && sink.mouse_move) {
            const float dt = (float)std::min(100.0, t_ms - last_t_) / 1000.f;
            sink.mouse_move(p.rx * s.rotate_speed * dt, -p.ry * s.rotate_speed * dt);
        }
        if (!layer) {
            int dir = p.ry > s.wheel_threshold ? 1 : (p.ry < -s.wheel_threshold ? -1 : 0);
            if (dir == 0) wheel_dir_ = 0;
            else if (dir != wheel_dir_ || t_ms - wheel_t_ >= s.wheel_repeat_ms) {
                wheel_dir_ = dir; wheel_t_ = t_ms;
                if (sink.wheel) sink.wheel(dir, dir > 0 ? "scrollup" : "scrolldown");
            }
        } else wheel_dir_ = 0;

        // Menu button: tap = Esc (Pause / dismount), hold = recentre.
        const bool start = (p.buttons & PAD_START) != 0;
        if (start && !(last_.buttons & PAD_START)) { start_t_ = t_ms; start_long_ = false; }
        if (start && !start_long_ && t_ms - start_t_ >= s.menu_hold_ms) { start_long_ = true; if (sink.recenter) sink.recenter(); }
        if (!start && (last_.buttons & PAD_START) && !start_long_ && armed_start_) tap_action("pause", "menu_tap");
        if (!start) armed_start_ = true;

        last_ = p; last_t_ = t_ms;
    }

    // Release everything that is held (focus loss, tracking loss, disable). Buttons still physically held
    // stay disarmed until released and pressed again, so they can't turn into a new context's action.
    void release_all(const std::string& why) {
        for (auto& [k, n] : key_refs_) if (n > 0 && sink.key) sink.key(k, false, "release_all:" + why);
        key_refs_.clear();
        for (auto& [bit, b] : buttons_) { b.action.clear(); b.armed = false; }
        rt_down_ = lt_down_ = fwd_ = back_ = left_ = right_ = run_ = rotate_ = false;
        rt_armed_ = lt_armed_ = false; run_latched_ = false; armed_start_ = false; wheel_dir_ = 0;
        if (layer_) { layer_ = false; if (sink.layer_changed) sink.layer_changed(false); }
    }

    const std::map<std::string, int>& held_keys() const { return key_refs_; }

private:
    struct Btn { std::string action; bool armed{true}; };
    std::map<uint16_t, Btn> buttons_;
    std::map<std::string, int> key_refs_;   // key name -> how many sources hold it
    PadState last_{};
    double last_t_{0}, wheel_t_{0}, start_t_{0};
    bool layer_{false}, rt_down_{false}, lt_down_{false}, rt_armed_{true}, lt_armed_{true};
    bool fwd_{false}, back_{false}, left_{false}, right_{false}, run_{false}, rotate_{false}, run_latched_{false};
    bool start_long_{false}, armed_start_{true};
    int wheel_dir_{0};

    std::string key_for(const std::string& action) const {
        auto it = bindings.find(action);
        return it == bindings.end() ? std::string{} : it->second;
    }
    void press(const std::string& action, const std::string& why) {
        auto k = key_for(action); if (k.empty()) return;
        if (key_refs_[k]++ == 0 && sink.key) sink.key(k, true, action + " <- " + why);
    }
    void release(const std::string& action, const std::string& why) {
        auto k = key_for(action); if (k.empty()) return;
        auto it = key_refs_.find(k); if (it == key_refs_.end() || it->second <= 0) return;
        if (--it->second == 0) { key_refs_.erase(it); if (sink.key) sink.key(k, false, action + " <- " + why); }
    }
    void tap_action(const std::string& action, const std::string& why) { press(action, why); release(action, why); }

    void button(uint16_t bit, const PadState& p, const char* base, const char* layered) {
        auto& b = buttons_[bit];
        const bool now = (p.buttons & bit) != 0, was = (last_.buttons & bit) != 0;
        if (!now) { if (!b.action.empty()) { release(b.action, name(bit)); b.action.clear(); } b.armed = true; return; }
        if (now && !was && b.armed) { b.action = layer_ ? layered : base; press(b.action, name(bit)); }
    }
    void analog_trigger(bool& down, float v, const char* action, const char* why) {
        bool& armed = (std::string(why) == "r_trigger") ? rt_armed_ : lt_armed_;
        if (!down && v >= s.trigger_press && armed) { down = true; press(action, why); }
        else if (down && v <= s.trigger_release) { down = false; release(action, why); }
        if (!down && v <= s.trigger_release) armed = true;
    }
    void hold_action(bool& state, bool want, const char* action, const char* why) {
        if (want && !state) { state = true; press(action, why); }
        else if (!want && state) { state = false; release(action, why); }
    }
    static const char* name(uint16_t bit) {
        switch (bit) {
            case PAD_A: return "a"; case PAD_B: return "b"; case PAD_X: return "x"; case PAD_Y: return "y";
            case PAD_RSHOULDER: return "r_grip"; case PAD_LSHOULDER: return "l_grip";
            case PAD_RTHUMB: return "r_thumb"; case PAD_LTHUMB: return "l_thumb"; case PAD_START: return "menu";
        }
        return "?";
    }
    static PadState swap_hands(PadState p) {
        PadState q = p;
        std::swap(q.lt, q.rt); std::swap(q.lx, q.rx); std::swap(q.ly, q.ry);
        auto sw = [&](uint16_t a, uint16_t b) {
            bool ha = p.buttons & a, hb = p.buttons & b;
            q.buttons &= ~(a | b); if (ha) q.buttons |= b; if (hb) q.buttons |= a;
        };
        sw(PAD_LSHOULDER, PAD_RSHOULDER); sw(PAD_LTHUMB, PAD_RTHUMB); sw(PAD_A, PAD_X); sw(PAD_B, PAD_Y);
        return q;
    }
};

}  // namespace votv
