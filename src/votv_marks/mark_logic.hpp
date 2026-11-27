// VOTV VR marks: pure logic (no Windows or UEVR calls), unit-tested by mark_logic_test.cpp.
//   - Trigger: edge detector for the mark chord / key with a minimum interval between marks.
//   - Json: a tiny JSON writer (objects, arrays, strings with escaping, numbers, bools, null).
//   - Settings parsing (key=value text, same format as votv_controls.txt).
#pragma once

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace votv_marks {

// Fires once on the rising edge of `down`, and only if at least min_interval_ms passed since the last fire.
// A press that was rate-limited stays used up until released (it can't fire later while still held).
struct Trigger {
    double min_interval_ms{1000};
    bool update(bool down, double t_ms) {
        bool fire = false;
        if (down && !was_ && (last_fire_ < 0 || t_ms - last_fire_ >= min_interval_ms)) { fire = true; last_fire_ = t_ms; }
        was_ = down;
        return fire;
    }
    void reset() { was_ = true; }   // treat as held: needs a release before the next fire
private:
    bool was_{false};
    double last_fire_{-1};
};

// The chord: modifier held, then the button pressed. Only the button's press counts (pressing the
// modifier while already holding the button does nothing), so a stick click made for something else
// never turns into a mark when the grip is squeezed afterwards.
struct Chord {
    bool update(bool modifier, bool button) {
        if (button && !button_was_) with_mod_ = modifier;   // decided at the button's press
        if (!button) with_mod_ = false;
        button_was_ = button;
        return button && with_mod_;
    }
private:
    bool button_was_{false}, with_mod_{false};
};

inline std::string json_escape(const std::string& s) {
    std::string o;
    o.reserve(s.size() + 2);
    for (unsigned char c : s) {
        switch (c) {
            case '"': o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n"; break;
            case '\r': o += "\\r"; break;
            case '\t': o += "\\t"; break;
            default:
                if (c < 0x20) { char b[8]; std::snprintf(b, sizeof(b), "\\u%04x", c); o += b; }
                else o += (char)c;
        }
    }
    return o;
}

// Minimal streaming JSON writer with indentation. Usage: j.begin_obj(); j.key("a"); j.num(1); j.end_obj();
class Json {
public:
    std::string out;
    void begin_obj() { value_prefix(); out += "{"; stack_.push_back({true, true}); }
    void end_obj() { close('}'); }
    void begin_arr() { value_prefix(); out += "["; stack_.push_back({false, true}); }
    void end_arr() { close(']'); }
    void key(const std::string& k) {
        auto& f = stack_.back();
        if (!f.first) out += ",";
        f.first = false;
        newline();
        out += "\"" + json_escape(k) + "\": ";
        after_key_ = true;
    }
    void str(const std::string& s) { value_prefix(); out += "\"" + json_escape(s) + "\""; }
    void num(double v, int decimals = 3) {
        value_prefix();
        if (!std::isfinite(v)) { out += "null"; return; }
        char b[64]; std::snprintf(b, sizeof(b), "%.*f", decimals, v);
        // trim trailing zeros ("1.500" -> "1.5", "2.000" -> "2")
        std::string s = b;
        if (s.find('.') != std::string::npos) {
            while (!s.empty() && s.back() == '0') s.pop_back();
            if (!s.empty() && s.back() == '.') s.pop_back();
        }
        if (s == "-0") s = "0";
        out += s;
    }
    void boolean(bool b) { value_prefix(); out += b ? "true" : "false"; }
    void null() { value_prefix(); out += "null"; }
    void vec3(float x, float y, float z, int decimals = 3) { begin_arr_inline(); num(x, decimals); num(y, decimals); num(z, decimals); end_arr_inline(); }
    void vec4(float x, float y, float z, float w, int decimals = 4) { begin_arr_inline(); num(x, decimals); num(y, decimals); num(z, decimals); num(w, decimals); end_arr_inline(); }
    // key + value helpers
    void kv(const std::string& k, const std::string& v) { key(k); str(v); }
    void kv(const std::string& k, const char* v) { key(k); if (v) str(v); else null(); }
    void kv(const std::string& k, double v, int decimals = 3) { key(k); num(v, decimals); }
    void kv(const std::string& k, int v) { key(k); num(v, 0); }
    void kv(const std::string& k, bool v) { key(k); boolean(v); }
    void kv_or_null(const std::string& k, const std::string& v) { key(k); if (v.empty()) null(); else str(v); }

private:
    struct Frame { bool obj; bool first; bool inl{false}; };
    std::vector<Frame> stack_;
    bool after_key_{false};
    void newline() { out += "\n"; out.append(stack_.size() * 2, ' '); }
    void value_prefix() {
        if (after_key_) { after_key_ = false; return; }
        if (stack_.empty()) return;
        auto& f = stack_.back();
        if (!f.first) out += f.inl ? ", " : ",";
        f.first = false;
        if (!f.inl) newline();
    }
    void close(char c) {
        bool empty = stack_.back().first;
        bool inl = stack_.back().inl;
        stack_.pop_back();
        if (!empty && !inl) newline();
        out += c;
    }
    void begin_arr_inline() { value_prefix(); out += "["; stack_.push_back({false, true, true}); }
    void end_arr_inline() { close(']'); }
};

// key=value settings text (lines, '#' comments). Returns def if missing or empty.
inline std::string setting_str(const std::string& text, const std::string& key, const std::string& def = "") {
    size_t pos = 0;
    while (pos < text.size()) {
        size_t eol = text.find('\n', pos);
        std::string line = text.substr(pos, eol == std::string::npos ? std::string::npos : eol - pos);
        pos = eol == std::string::npos ? text.size() : eol + 1;
        while (!line.empty() && (line.back() == '\r' || line.back() == ' ' || line.back() == '\t')) line.pop_back();
        size_t a = line.find_first_not_of(" \t");
        if (a == std::string::npos || line[a] == '#') continue;
        line = line.substr(a);
        if (line.compare(0, key.size(), key) == 0 && line.size() > key.size() && line[key.size()] == '=') {
            std::string v = line.substr(key.size() + 1);
            return v.empty() ? def : v;
        }
    }
    return def;
}
inline double setting_num(const std::string& text, const std::string& key, double def) {
    std::string v = setting_str(text, key);
    if (v.empty()) return def;
    char* end = nullptr;
    double d = std::strtod(v.c_str(), &end);
    return end == v.c_str() ? def : d;
}

// Mark folder name from local time parts: 2026-11-27_02-20-15_123
inline std::string folder_name(int y, int mo, int d, int h, int mi, int s, int ms) {
    char b[64];
    std::snprintf(b, sizeof(b), "%04d-%02d-%02d_%02d-%02d-%02d_%03d", y, mo, d, h, mi, s, ms);
    return b;
}

}  // namespace votv_marks
