// Offline tests for pointer_math.hpp. Exit code 0 = all pass.
#include <cmath>
#include <cstdio>

#include "pointer_math.hpp"

using namespace votv;

static int fails = 0;
static void check(bool ok, const char* what) {
    std::printf("%s  %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok) ++fails;
}
static bool near(float a, float b, float eps = 1e-3f) { return std::fabs(a - b) < eps; }

static Quat yaw_quat(float deg) {  // rotation about +Y
    float r = deg * 3.14159265f / 180.f;
    return {0, std::sin(r / 2), 0, std::cos(r / 2)};
}
static Quat pitch_quat(float deg) {  // rotation about +X (positive = look up)
    float r = deg * 3.14159265f / 180.f;
    return {std::sin(r / 2), 0, 0, std::cos(r / 2)};
}
static Quat mul(Quat a, Quat b) {
    return {a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y, a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w, a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z};
}

int main() {
    ScreenModel m;  // 2 m away, 2 m wide, 16:9
    Vec3 head{0, 1.6f, 0};

    // Identity head: screen centred straight ahead (-Z).
    auto s = place_screen(head, Quat{}, m);
    check(s.has_value(), "screen placed for identity head");
    check(near(s->center.z, -2.f) && near(s->center.y, 1.6f), "screen centre 2 m ahead at head height");
    check(near(s->right.x, 1.f), "screen right = +X when looking down -Z");

    // Ray straight from the head forward hits the centre.
    auto h = hit_screen(*s, head, {0, 0, -1});
    check(h && near(h->u, 0.5f) && near(h->v, 0.5f) && h->on_screen, "forward ray hits centre (0.5, 0.5)");

    // Ray to the top-left corner.
    Vec3 tl = s->center + s->right * (-s->width / 2) + s->up * (s->height / 2);
    h = hit_screen(*s, head, normalize(tl - head));
    check(h && near(h->u, 0.f) && near(h->v, 0.f), "ray to top-left corner -> (0, 0)");

    // Right of centre -> u > 0.5; below -> v > 0.5.
    h = hit_screen(*s, head, normalize(Vec3{0.5f, -0.2f, -2.f}));
    check(h && h->u > 0.5f && h->v > 0.5f, "right/below -> u>0.5, v>0.5");

    // Pointing backwards: no hit.
    check(!hit_screen(*s, head, {0, 0, 1}).has_value(), "ray pointing away: no hit");

    // Head yawed 90 deg left (+Y rotation turns -Z toward -X): screen follows yaw.
    s = place_screen(head, yaw_quat(90), m);
    check(s && near(s->center.x, -2.f) && near(s->center.z, 0.f), "yaw 90: screen moves to -X");
    h = hit_screen(*s, head, forward_of(yaw_quat(90)));
    check(h && near(h->u, 0.5f) && near(h->v, 0.5f), "yaw 90: forward ray still hits centre");

    // Head pitched up 30 deg: screen does NOT follow pitch, stays at head height.
    s = place_screen(head, mul(yaw_quat(0), pitch_quat(30)), m);
    check(s && near(s->center.y, 1.6f) && near(s->center.z, -2.f), "pitch 30: screen stays level at head height");

    // Controller offset to the right, pointing straight ahead: hits right of centre.
    s = place_screen(head, Quat{}, m);
    h = hit_screen(*s, Vec3{0.3f, 1.4f, -0.3f}, {0, 0, -1});
    check(h && near(h->u, 0.5f + 0.3f / 2.f) && h->v > 0.5f, "controller 30 cm right, 20 cm low, pointing ahead");

    // Hysteresis.
    Hysteresis tr;
    int a = tr.update(0.5f), b = tr.update(0.7f), c = tr.update(0.5f), d = tr.update(0.3f);
    check(a == 0 && b == 1 && c == 0 && d == -1, "trigger hysteresis press/hold/release");

    std::printf("%s (%d failed)\n", fails ? "FAILED" : "ALL PASS", fails);
    return fails ? 1 : 0;
}
