// VALIDATION BRANCH ONLY. Diagnostic for CI_Toolkit #151.
//
// Round 2. Round 1 showed a v71-declared method failing because the document's version
// was unparseable ("Version provided doesn't fit the format <Major>.<Minor>", upgrades
// reported "from version ?.?"), so the v7.1 converter was never applied and the
// MessageForDeleted entry was never consulted. But that payload came from dataset 2.4,
// which #158 says --test-all omits, so it is not one of the eight candidates.
//
// This round tests the SAME declared method across EVERY dataset version it appears in,
// and reports per version: the parsed version, whether the version was parseable, whether
// the "No upgrade for" event fired, and the result. That separates "only the omitted
// early datasets are broken" from "all of them are".

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
var vm = FT("BH.Engine.Versioning.Modify");
var bd = FT("MongoDB.Bson.BsonDocument");
var fromJson = FM(FT("BH.Engine.Serialiser.Convert"), "FromJson", 1);
var clear = FM(bc, "ClearCurrentEvents", 0);
var cur = FM(bq, "CurrentEvents", 0);
var parse = bd.GetMethod("Parse", BindingFlags.Public | BindingFlags.Static, null, new[] { typeof(string) }, null);
var getKey = FM(vm, "GetMethodKey", 1);
var docVersion = FM(vq, "Version", 1);   // BsonDocument.Version()

Console.WriteLine($"installed BHoMVersion(): {FM(bq, "BHoMVersion", 0)?.Invoke(null, null)}");
Console.WriteLine($"Query.Version(doc) available: {docVersion is not null}");

const string Target = "IsLongitudinal";
string root = @"C:\ProgramData\BHoM\Datasets\TestSets\Versioning";

// Every dataset version containing the target, with one payload each.
var found = new List<(string Ver, string Payload)>();
foreach (var dir in Directory.GetDirectories(root).OrderBy(x => x, StringComparer.Ordinal))
{
    foreach (var file in Directory.GetFiles(dir, "*.json"))
    {
        string hit = File.ReadLines(file).FirstOrDefault(l => l.Contains(Target));
        if (hit is not null) { found.Add((Path.GetFileName(dir), hit.Trim().TrimEnd(','))); break; }
    }
}
Console.WriteLine($"\ndataset versions containing '{Target}': {found.Count} -> {string.Join(", ", found.Select(f => f.Ver))}");
Console.WriteLine("(#158 records --test-all as omitting 2.4, 3.0, 3.1)\n");

Console.WriteLine($"{"dataset",-9} {"doc.Version()",-14} {"parseable",-10} {"keyInV71",-9} {"detected",-9} {"result",-8} events");
Console.WriteLine(new string('-', 82));

foreach (var (ver, payload) in found)
{
    object doc = null; string parsedVer = "?";
    try { doc = parse.Invoke(null, new object[] { payload }); } catch { }
    if (doc is not null && docVersion is not null)
    { try { parsedVer = docVersion.Invoke(null, new[] { doc })?.ToString() ?? "null"; } catch (Exception e) { parsedVer = "throw:" + (e.InnerException ?? e).GetType().Name; } }

    string key = "";
    try { key = (string)getKey.Invoke(null, new[] { doc }); } catch { }

    bool inV71 = false;
    var conv = vq.GetMethods(BindingFlags.Public | BindingFlags.Static).FirstOrDefault(m => m.Name == "Converter" && m.GetParameters().Length == 1);
    try
    {
        object c = conv.Invoke(null, new object[] { "7.1" });
        var mfd = c?.GetType().GetProperty("MessageForDeleted")?.GetValue(c) as System.Collections.IDictionary;
        inV71 = mfd is not null && key is not null && mfd.Contains(key);
    }
    catch { }

    clear?.Invoke(null, null);
    object res = null;
    try { res = fromJson.Invoke(null, new object[] { payload }); } catch { }

    bool detected = false, badVersion = false; int n = 0;
    foreach (var e in (cur?.Invoke(null, null) as System.Collections.IEnumerable) ?? Array.Empty<object>())
    {
        n++;
        var m = e.GetType().GetProperty("Message")?.GetValue(e)?.ToString() ?? "";
        if (m.StartsWith("No upgrade for", StringComparison.Ordinal)) detected = true;
        if (m.Contains("doesn't fit the format")) badVersion = true;
    }

    Console.WriteLine($"{ver,-9} {parsedVer,-14} {(badVersion ? "NO" : "yes"),-10} {inV71,-9} {detected,-9} {(res is null ? "NULL" : "ok"),-8} {n}");
}

Console.WriteLine("\ndetected=True means FromJson.cs:226 passes the item (declared deletion honoured).");
