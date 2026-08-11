// VALIDATION BRANCH ONLY. Diagnostic for CI_Toolkit #151.
//
// Round 3. Round 2 established the boundary: a deletion declared in v71 is honoured
// ("No upgrade for" raised, FromJson.cs:226 passes the item) for dataset versions 5.0
// and above, and silently not honoured for 4.3 and below. Datasets <=4.3 emit 5 events,
// >=5.0 emit 7. Version parsing does not explain it: 4.2 and 4.3 report a parseable
// doc.Version() and are still not honoured.
//
// This round dumps every event message either side of the boundary so the two extra
// events at 5.0 can be identified, which is what an upstream report needs.

using System.Reflection;
using System.Runtime.Loader;

AssemblyLoadContext.Default.Resolving += static (ctx, n) =>
{
    if (!string.Equals(n.Name, "System.Drawing.Common", StringComparison.Ordinal)) return null;
    var l = AssemblyLoadContext.Default.Assemblies.FirstOrDefault(a => a.GetName().Name == "System.Drawing.Common");
    if (l is not null) return l;
    try { return ctx.LoadFromAssemblyName(new AssemblyName("System.Drawing.Common")); } catch { return null; }
};

var asms = new List<Assembly>();
foreach (var f in Directory.GetFiles(@"C:\ProgramData\BHoM\Assemblies", "*.dll"))
{ try { asms.Add(Assembly.LoadFrom(f)); } catch { } }

Type FT(string s) { foreach (var a in asms) { try { var t = a.GetType(s, false); if (t is not null) return t; } catch { } } return null; }
MethodInfo FM(Type t, string n, int c) => t?.GetMethods(BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic)
    .FirstOrDefault(m => m.Name == n && m.GetParameters().Length == c);

var bq = FT("BH.Engine.Base.Query");
var bc = FT("BH.Engine.Base.Compute");
var vq = FT("BH.Engine.Versioning.Query");
var fromJson = FM(FT("BH.Engine.Serialiser.Convert"), "FromJson", 1);
var clear = FM(bc, "ClearCurrentEvents", 0);
var cur = FM(bq, "CurrentEvents", 0);
var upg = FM(vq, "UpgradersToCall", 1);

const string Target = "IsLongitudinal";
string root = @"C:\ProgramData\BHoM\Datasets\TestSets\Versioning";

foreach (var ver in new[] { "4.1", "4.2", "4.3", "5.0", "5.1" })
{
    string dir = Path.Combine(root, ver);
    if (!Directory.Exists(dir)) { Console.WriteLine($"\n===== {ver}: dataset dir absent"); continue; }

    string payload = null;
    foreach (var file in Directory.GetFiles(dir, "*.json"))
    {
        string hit = File.ReadLines(file).FirstOrDefault(l => l.Contains(Target));
        if (hit is not null) { payload = hit.Trim().TrimEnd(','); break; }
    }
    if (payload is null) { Console.WriteLine($"\n===== {ver}: '{Target}' not present"); continue; }

    var walk = upg?.Invoke(null, new object[] { ver }) as System.Collections.IEnumerable;
    Console.WriteLine($"\n===== dataset {ver} =====");
    Console.WriteLine($"  UpgradersToCall(\"{ver}\") -> [{string.Join(", ", (walk ?? Array.Empty<object>()).Cast<object>())}]");

    clear?.Invoke(null, null);
    object res = null; string threw = null;
    try { res = fromJson.Invoke(null, new object[] { payload }); }
    catch (Exception e) { threw = (e.InnerException ?? e).Message; }

    int i = 0; bool detected = false;
    foreach (var e in (cur?.Invoke(null, null) as System.Collections.IEnumerable) ?? Array.Empty<object>())
    {
        i++;
        var m = (e.GetType().GetProperty("Message")?.GetValue(e)?.ToString() ?? "").Replace("\n", " | ");
        var ty = e.GetType().GetProperty("Type")?.GetValue(e)?.ToString() ?? "";
        if (m.StartsWith("No upgrade for", StringComparison.Ordinal)) detected = true;
        Console.WriteLine($"  [{i}] {ty,-8} {m.Substring(0, Math.Min(200, m.Length))}");
    }
    Console.WriteLine($"  result={(res is null ? "NULL" : res.GetType().Name)}{(threw is null ? "" : " threw:" + threw)}  events={i}  detected={detected}");
}
