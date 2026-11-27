// Offline checks of mark_logic.hpp. Prints PASS/FAIL lines and a VERDICT.
#include <cstdio>
#include <string>

#include "mark_logic.hpp"

using namespace votv_marks;

static int fails = 0, total = 0;
static void check(const char* name, bool ok, const std::string& detail = "") {
    ++total;
    if (!ok) ++fails;
    std::printf("%s %s%s%s\n", ok ? "PASS" : "FAIL", name, detail.empty() ? "" : "  ", detail.c_str());
}

int main() {
    {   // chord: grip held, then stick click = one mark
        Chord c; Trigger t; int n = 0; double ms = 0;
        auto step = [&](bool g, bool b) { ms += 11; if (t.update(c.update(g, b), ms)) ++n; };
        step(false, false); step(true, false); step(true, true); step(true, true); step(true, false); step(false, false);
        check("grip then click = 1 mark", n == 1, std::to_string(n));
    }
    {   // stick click first (flashlight), grip squeezed afterwards: no mark
        Chord c; Trigger t; int n = 0; double ms = 0;
        auto step = [&](bool g, bool b) { ms += 11; if (t.update(c.update(g, b), ms)) ++n; };
        step(false, true); step(true, true); step(true, true); step(true, false); step(false, false);
        check("click then grip = no mark", n == 0, std::to_string(n));
    }
    {   // two quick clicks within the minimum interval: one mark; after the interval: second mark
        Chord c; Trigger t; t.min_interval_ms = 1000; int n = 0; double ms = 0;
        auto step = [&](bool g, bool b, double dt = 11) { ms += dt; if (t.update(c.update(g, b), ms)) ++n; };
        step(true, true); step(true, false); step(true, true, 200); step(true, false);
        check("rate limit within 1 s", n == 1, std::to_string(n));
        step(true, true, 1200); step(true, false);
        check("second mark after interval", n == 2, std::to_string(n));
    }
    {   // releasing the grip while the click is held ends the chord; re-squeezing doesn't re-fire
        Chord c; Trigger t; t.min_interval_ms = 0; int n = 0; double ms = 0;
        auto step = [&](bool g, bool b) { ms += 11; if (t.update(c.update(g, b), ms)) ++n; };
        step(true, true); step(false, true); step(true, true); step(true, false);
        check("grip re-squeeze while clicking = still 1", n == 1, std::to_string(n));
    }
    {   // JSON escaping and shape
        Json j; j.begin_obj(); j.kv("a", std::string("q\"uo\\te\nx")); j.kv("n", 1.5); j.kv("z", 2.0);
        j.key("v"); j.vec3(1, 2.25f, -0.0f); j.key("e"); j.begin_arr(); j.end_arr(); j.kv_or_null("nn", ""); j.end_obj();
        const std::string want = "{\n  \"a\": \"q\\\"uo\\\\te\\nx\",\n  \"n\": 1.5,\n  \"z\": 2,\n  \"v\": [1, 2.25, 0],\n  \"e\": [],\n  \"nn\": null\n}";
        check("json output", j.out == want, j.out);
        Json k; k.begin_obj(); k.kv("c", std::string("\x01")); k.end_obj();
        check("json control char", k.out.find("\\u0001") != std::string::npos, k.out);
        Json m; m.begin_obj(); m.key("o"); m.begin_obj(); m.kv("x", 1); m.end_obj(); m.end_obj();
        check("json nested", m.out == "{\n  \"o\": {\n    \"x\": 1\n  }\n}", m.out);
    }
    {   // settings
        std::string t = "# c\r\nmark_dir=F:\\x\\marks\r\nmark_key=F8\nmark_trace_cm=1500\n  mark_haptic=0\nmark_empty=\n";
        check("setting str", setting_str(t, "mark_dir") == "F:\\x\\marks", setting_str(t, "mark_dir"));
        check("setting num", setting_num(t, "mark_trace_cm", 0) == 1500);
        check("setting indented", setting_num(t, "mark_haptic", 5) == 0);
        check("setting empty -> default", setting_str(t, "mark_empty", "d") == "d");
        check("setting missing", setting_num(t, "nope", 7) == 7);
        check("setting prefix not matched", setting_str(t, "mark", "none") == "none");
    }
    check("folder name", folder_name(2026, 11, 27, 2, 5, 9, 7) == "2026-11-27_02-05-09_007");
    std::printf("VERDICT %s (%d of %d failed)\n", fails ? "FAIL" : "PASS", fails, total);
    return fails ? 1 : 0;
}
