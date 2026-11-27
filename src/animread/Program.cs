// Reads the game's own Kerfur Omega finger animation and writes the open-hand and fist finger rotations
// (per bone, relative to the reference pose, bone-local quaternions x y z w) for votv_hands.lua.
// Open = kerfurOmegaV1_a_givePaper frame 12 (the game's most open right hand; its left hand is not animated, so the
// left side is the mirror: x, -y, -z, w), fist = kerfurOmegaV1_a_idle frame 0 (the Kerfur's default hand).
// Usage: animread <Paks dir> <out.txt>. Output is derived from game data: keep it out of the repo.
using CUE4Parse.FileProvider;
using CUE4Parse.UE4.Versions;
using CUE4Parse.UE4.Assets.Exports.Animation;
using CUE4Parse.UE4.Objects.Core.Math;
using CUE4Parse_Conversion.Animations;

var provider = new DefaultFileProvider(args[0], SearchOption.TopDirectoryOnly, new VersionContainer(EGame.GAME_UE4_27));
provider.Initialize();
provider.Mount();
const string Dir = "VotV/Content/meshes/kerfurAnthro/sk/";
var skel = provider.LoadPackageObject<USkeleton>(Dir + "kerfurOmegaV1_Skeleton.kerfurOmegaV1_Skeleton");
var names = skel.ReferenceSkeleton.FinalRefBoneInfo.Select(b => b.Name.Text).ToList();
var refPose = skel.ReferenceSkeleton.FinalRefBonePose;
var Load = (string n) => skel.ConvertAnims(provider.LoadPackageObject<UAnimSequence>(Dir + "anim/" + n + "." + n)).Sequences[0];
var open = Load("kerfurOmegaV1_a_givePaper");
var fist = Load("kerfurOmegaV1_a_idle");

float[] Delta(dynamic s, string bone, int frame)
{
    int i = names.IndexOf(bone);
    FQuat[] k = s.Tracks[i].KeyQuat; FQuat q = k[Math.Min(frame, k.Length - 1)]; var r = refPose[i].Rotation;
    // inverse(ref) * key, Hamilton product
    float ax = -r.X, ay = -r.Y, az = -r.Z, aw = r.W;
    var d = new[] { aw * q.X + ax * q.W + ay * q.Z - az * q.Y, aw * q.Y - ax * q.Z + ay * q.W + az * q.X,
                    aw * q.Z + ax * q.Y - ay * q.X + az * q.W, aw * q.W - ax * q.X - ay * q.Y - az * q.Z };
    return d[3] < 0 ? d.Select(v => -v).ToArray() : d;
}
string F(float[] q) => string.Join(" ", q.Select(v => v.ToString("F5", System.Globalization.CultureInfo.InvariantCulture)));

var lines = new List<string>();
for (int f = 1; f <= 4; f++)
    for (int j = 1; j <= 3; j++)
    {
        var o = Delta(open, $"finger_{f}_{j}_R", 12);
        lines.Add($"finger_{f}_{j}_R {F(o)} {F(Delta(fist, $"finger_{f}_{j}_R", 0))}");
        lines.Add($"finger_{f}_{j}_L {F(new[] { o[0], -o[1], -o[2], o[3] })} {F(Delta(fist, $"finger_{f}_{j}_L", 0))}");
    }
File.WriteAllLines(args[1], lines);
Console.WriteLine($"wrote {lines.Count} finger poses to {args[1]}");
