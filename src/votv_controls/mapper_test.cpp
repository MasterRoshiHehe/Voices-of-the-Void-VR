// Offline checks of the controller mapping (mapper.hpp). Prints PASS/FAIL lines and a VERDICT.
#include <cstdio>
#include <string>
#include <vector>

#include "mapper.hpp"

using namespace votv;

struct Rec {
    std::vector<std::string> ev;
    Mapper m;
    Rec() {
        m.sink.key = [this](const std::string& k, bool d, const std::string&) { ev.push_back((d ? "+" : "-") + k); };
        m.sink.wheel = [this](int n, const std::string&) { ev.push_back("wheel" + std::to_string(n)); };
        m.sink.mouse_move = [this](float, float) { ev.push_back("move"); };
        m.sink.recenter = [this]() { ev.push_back("recenter"); };
        m.sink.layer_changed = [this](bool on) { ev.push_back(on ? "layer+" : "layer-"); };
    }
    double t = 0;
    void step(PadState p, double dt = 11) { t += dt; m.update(p, t); }
    std::string take() { std::string s; for (auto& e : ev) s += e + " "; ev.clear(); if (!s.empty()) s.pop_back(); return s; }
};

static int fails = 0;
static void check(const char* name, const std::string& got, const std::string& want) {
    bool ok = got == want;
    if (!ok) ++fails;
    std::printf("%s %s%s%s\n", ok ? "PASS" : "FAIL", name, ok ? "" : ("  got [" + got + "] want [" + want + "]").c_str(), "");
}

static PadState pad(uint16_t b = 0) { PadState p; p.buttons = b; return p; }

int main() {
    {   // right grip = E (use), held for the whole press, released once
        Rec r; r.step(pad()); r.step(pad(PAD_RSHOULDER)); r.step(pad(PAD_RSHOULDER), 500); r.step(pad());
        check("grip sends E press/hold/release", r.take(), "+E -E");
    }
    {   // trigger hysteresis: 0.5 no press, 0.6 press, 0.4 still held, 0.3 release
        Rec r; PadState p; p.rt = 0.5f; r.step(p); p.rt = 0.6f; r.step(p); p.rt = 0.4f; r.step(p); p.rt = 0.3f; r.step(p);
        check("trigger hysteresis LMB", r.take(), "+LeftMouseButton -LeftMouseButton");
    }
    {   // layer: left grip + A = middle mouse; A alone = space
        Rec r; r.step(pad(PAD_A)); r.step(pad());
        check("A = jump", r.take(), "+SpaceBar -SpaceBar");
        r.step(pad(PAD_LSHOULDER)); r.step(pad(PAD_LSHOULDER | PAD_A)); r.step(pad(PAD_LSHOULDER)); r.step(pad());
        check("left grip + A = lockObject", r.take(), "layer+ +MiddleMouseButton -MiddleMouseButton layer-");
    }
    {   // press A, then grab the layer while holding A, then release: Space is released, no MMB
        Rec r; r.step(pad(PAD_A)); r.step(pad(PAD_A | PAD_LSHOULDER)); r.step(pad(PAD_LSHOULDER)); r.step(pad());
        check("layer change mid-press releases original key", r.take(), "+SpaceBar layer+ -SpaceBar layer-");
    }
    {   // left stick diagonal -> W + D; back to centre releases both
        Rec r; PadState p; p.ly = 0.8f; p.lx = 0.8f; r.step(p); r.step(pad());
        check("stick diagonal", r.take(), "+W +D -W -D");
    }
    {   // run latch: click while moving, release click, keep moving -> Shift stays; centre -> Shift up
        Rec r; PadState p; p.ly = 0.9f; r.step(p); p.buttons = PAD_LTHUMB; r.step(p); p.buttons = 0; r.step(p); r.step(p, 400);
        r.step(pad());
        check("run latched until stick centred", r.take(), "+W +LeftShift -W -LeftShift");
    }
    {   // menu tap = Escape; hold = recentre only
        Rec r; r.step(pad(PAD_START)); r.step(pad(PAD_START), 200); r.step(pad());
        check("menu tap = Esc", r.take(), "+Escape -Escape");
        r.step(pad(PAD_START)); r.step(pad(PAD_START), 1100); r.step(pad());
        check("menu hold = recentre, no Esc", r.take(), "recenter");
    }
    {   // right stick up = wheel up once, repeats after 250 ms
        Rec r; PadState p; p.ry = 0.9f; r.step(p); r.step(p, 100); r.step(p, 200); r.step(pad());
        check("wheel notch + repeat", r.take(), "wheel1 wheel1");
    }
    {   // layer + right stick = RMB held + mouse moves; release stick -> RMB up
        Rec r; PadState p; p.buttons = PAD_LSHOULDER; r.step(p); p.rx = 0.8f; r.step(p); r.step(p); p.rx = 0; r.step(p); r.step(pad());
        check("rotate = RMB + mouse", r.take(), "layer+ +RightMouseButton move move -RightMouseButton layer-");
    }
    {   // release_all while grip held: E up, and E does not come back until grip is pressed again
        Rec r; r.step(pad(PAD_RSHOULDER)); r.m.release_all("focus"); r.step(pad(PAD_RSHOULDER)); r.step(pad());
        r.step(pad(PAD_RSHOULDER)); r.step(pad());
        check("focus loss releases and needs re-press", r.take(), "+E -E +E -E");
    }
    {   // left-handed: left grip acts as the right grip (E)
        Rec r; r.m.s.left_handed = true; r.step(pad(PAD_LSHOULDER)); r.step(pad());
        check("left-handed swap", r.take(), "+E -E");
    }
    {   // Input.ini parsing: rebinding use to F is honoured; modified bindings ignored
        auto b = parse_input_ini("ActionMappings=(ActionName=\"use\",bShift=False,bCtrl=False,bAlt=False,bCmd=False,Key=F)\n"
                                 "ActionMappings=(ActionName=\"Jump\",bShift=True,bCtrl=False,bAlt=False,bCmd=False,Key=J)\n");
        check("ini parse", b["use"] + "|" + (b.count("jump") ? b["jump"] : "none"), "F|none");
    }
    std::printf("VERDICT %s (%d failed)\n", fails ? "FAIL" : "PASS", fails);
    return fails ? 1 : 0;
}
