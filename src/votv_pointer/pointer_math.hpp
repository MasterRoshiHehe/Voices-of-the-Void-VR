// Laser-pointer math for the flat (2D) menu screen. Pure functions, no Windows/UEVR, unit-tested in
// pointer_test.cpp.
//
// Space: UEVR's VR tracking space as returned by API::VR::get_pose/get_aim_pose: metres, +Y up, the
// headset looking down -Z at identity rotation (OpenXR convention; logged at activation to confirm).
//
// Screen model (UEVR 1.05 2D screen mode, user report 2026-11-27 02:23): the flat screen follows the
// head's yaw but not its pitch. So it is modelled as a vertical rectangle centred `distance` metres in
// front of the headset along the headset's horizontal forward, at headset height plus `offset_up`,
// `width` x `width / aspect` metres. All of these are live settings; the defaults follow UEVR's
// UI_Distance=2 / UI_Size=2 and are expected to need calibration.
#pragma once

#include <cmath>
#include <optional>

namespace votv {

struct Vec3 { float x = 0, y = 0, z = 0; };
struct Quat { float x = 0, y = 0, z = 0, w = 1; };

inline Vec3 operator+(Vec3 a, Vec3 b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
inline Vec3 operator-(Vec3 a, Vec3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
inline Vec3 operator*(Vec3 a, float s) { return {a.x * s, a.y * s, a.z * s}; }
inline float dot(Vec3 a, Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline Vec3 cross(Vec3 a, Vec3 b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
inline float length(Vec3 a) { return std::sqrt(dot(a, a)); }
inline Vec3 normalize(Vec3 a) { float l = length(a); return l > 1e-6f ? a * (1.f / l) : Vec3{}; }

// Rotate v by unit quaternion q.
inline Vec3 rotate(Quat q, Vec3 v) {
    Vec3 u{q.x, q.y, q.z};
    Vec3 t = cross(u, v) * 2.f;
    return v + t * q.w + cross(u, t);
}

inline Vec3 forward_of(Quat q) { return rotate(q, {0, 0, -1}); }

struct ScreenModel {
    float distance = 2.0f;   // metres in front of the head
    float width = 2.0f;      // metres
    float aspect = 16.f / 9.f;
    float offset_up = 0.0f;  // metres, + = up
    float offset_right = 0.0f;
};

struct Screen {
    Vec3 center, right, up, normal;  // normal points back at the user
    float width = 2, height = 1.125f;
};

// Screen placed from the head pose: yaw follows the head, pitch and roll don't.
inline std::optional<Screen> place_screen(Vec3 head_pos, Quat head_rot, const ScreenModel& m) {
    Vec3 f = forward_of(head_rot);
    Vec3 fh{f.x, 0, f.z};
    if (length(fh) < 1e-3f) return std::nullopt;  // looking straight up/down: yaw undefined
    fh = normalize(fh);
    Screen s;
    s.up = {0, 1, 0};
    s.right = normalize(cross(fh, s.up));
    s.normal = fh * -1.f;
    s.center = head_pos + fh * m.distance + s.up * m.offset_up + s.right * m.offset_right;
    s.width = m.width;
    s.height = m.width / m.aspect;
    return s;
}

struct Hit { float u = 0, v = 0; float t = 0; bool on_screen = false; };

// Ray from the controller (origin, unit direction) against the screen. u,v in 0..1 (0,0 = top-left).
inline std::optional<Hit> hit_screen(const Screen& s, Vec3 origin, Vec3 dir) {
    float denom = dot(dir, s.normal);
    if (denom > -1e-4f) return std::nullopt;  // parallel or pointing away from the screen
    float t = dot(s.center - origin, s.normal) / denom;
    if (t <= 0) return std::nullopt;
    Vec3 p = origin + dir * t;
    Vec3 d = p - s.center;
    Hit h;
    h.t = t;
    h.u = 0.5f + dot(d, s.right) / s.width;
    h.v = 0.5f - dot(d, s.up) / s.height;
    h.on_screen = h.u >= 0 && h.u <= 1 && h.v >= 0 && h.v <= 1;
    return h;
}

// Calibration: express a controller ray in the head's yaw frame (x = right, y = up, z = forward, origin at the
// head) and intersect it with the plane z = distance. The flat screen follows head yaw, so corner hits taken
// in this frame at different moments are comparable.
struct Local2 { float x = 0, y = 0; bool ok = false; };
inline Local2 ray_on_plane_local(Vec3 head_pos, Quat head_rot, Vec3 origin, Vec3 dir, float distance) {
    Local2 r;
    Vec3 f = forward_of(head_rot);
    Vec3 fh{f.x, 0, f.z};
    if (length(fh) < 1e-3f) return r;
    fh = normalize(fh);
    Vec3 up{0, 1, 0};
    Vec3 right = normalize(cross(fh, up));
    Vec3 o = origin - head_pos;
    Vec3 ol{dot(o, right), o.y, dot(o, fh)};
    Vec3 dl{dot(dir, right), dir.y, dot(dir, fh)};
    if (dl.z < 1e-4f) return r;
    float t = (distance - ol.z) / dl.z;
    if (t <= 0) return r;
    r.x = ol.x + dl.x * t;
    r.y = ol.y + dl.y * t;
    r.ok = true;
    return r;
}

// Fit the screen model from the four corner hits (top-left, top-right, bottom-right, bottom-left) on the plane
// at `distance`. Width/height are averaged over opposite edges, the centre is the mean of the corners.
inline ScreenModel fit_screen(const Local2 c[4], float distance) {
    ScreenModel m;
    m.distance = distance;
    float w = ((c[1].x - c[0].x) + (c[2].x - c[3].x)) * 0.5f;
    float h = ((c[0].y - c[3].y) + (c[1].y - c[2].y)) * 0.5f;
    m.width = std::fabs(w);
    m.aspect = std::fabs(h) > 1e-4f ? std::fabs(w / h) : 16.f / 9.f;
    m.offset_right = (c[0].x + c[1].x + c[2].x + c[3].x) * 0.25f;
    m.offset_up = (c[0].y + c[1].y + c[2].y + c[3].y) * 0.25f;
    return m;
}

// Trigger with hysteresis: returns +1 on press, -1 on release, 0 otherwise.
struct Hysteresis {
    float on = 0.6f, off = 0.4f;
    bool down = false;
    int update(float value) {
        if (!down && value >= on) { down = true; return 1; }
        if (down && value <= off) { down = false; return -1; }
        return 0;
    }
};

}  // namespace votv
