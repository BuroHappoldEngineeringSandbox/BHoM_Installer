// VALIDATION BRANCH ONLY. Diagnostic for CI_Toolkit #151.
//
// Question: is a deletion declared in a version INSIDE the upgrade walk honoured on a
// clean MSI install? The framework's mechanism is Upgrade.cs:472 throw NoUpdateException
// -> ToNewVersion.cs:107 RecordError("No upgrade for ...") -> FromJson.cs:223 detected
// -> PassResult. UpgradersToCall walks the document's version up to BHoMVersion(), so a
// declaration newer than the installed version is unreachable. The eight full-history
// candidates are declared in v71 and v81, which ARE inside the walk for older datasets,
// so the version bound does not explain them.

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
Console.WriteLine($"loaded assemblies: {asms.Count}");

Type FT(string s) { foreach (var a in asms) { try { var t = a.GetType(s, false); if (t is not null) return t; } catch { } } return null; }
MethodInfo FM(Type t, string n, int c) => t?.GetMethods(BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic)
    .FirstOrDefault(m => m.Name == n && m.GetParameters().Length == c);

var bq = FT("BH.Engine.Base.Query");
var bc = FT("BH.Engine.Base.Compute");
var vq = FT("BH.Engine.Versioning.Query");
var vm = FT("BH.Engine.Versioning.Modify");
var bd = FT("MongoDB.Bson.BsonDocument");
Console.WriteLine($"types: BaseQuery={bq is not null} BaseCompute={bc is not null} VerQuery={vq is not null} VerModify={vm is not null} Bson={bd is not null}");

Console.WriteLine("installed BHoMVersion(): " + FM(bq, "BHoMVersion", 0)?.Invoke(null, null));

var upg = FM(vq, "UpgradersToCall", 1);
foreach (var v in new[] { "6.0", "7.0", "7.1", "8.0", "9.2" })
{
    var l = upg?.Invoke(null, new object[] { v }) as System.Collections.IEnumerable;
    Console.WriteLine($"  UpgradersToCall(\"{v}\") -> [{string.Join(", ", (l ?? Array.Empty<object>()).Cast<object>())}]");
}

// A method declared under MessageForDeleted in v71.
const string Target = "IsLongitudinal";
string root = @"C:\ProgramData\BHoM\Datasets\TestSets\Versioning";
Console.WriteLine($"\ndataset root exists: {Directory.Exists(root)}");
string payload = null, fromVer = null;
if (Directory.Exists(root))
{
    foreach (var dir in Directory.GetDirectories(root).OrderBy(x => x))
    {
        foreach (var file in Directory.GetFiles(dir, "*.json"))
        {
            foreach (var line in File.ReadLines(file))
                if (line.Contains(Target)) { payload = line.Trim().TrimEnd(','); fromVer = Path.GetFileName(dir); break; }
            if (payload is not null) break;
        }
        if (payload is not null) break;
    }
}
Console.WriteLine($"payload for '{Target}': {(payload is null ? "NOT FOUND" : $"dataset {fromVer}, {payload.Length} chars")}");
if (payload is null) return;

object doc = bd.GetMethod("Parse", BindingFlags.Public | BindingFlags.Static, null, new[] { typeof(string) }, null)
                .Invoke(null, new object[] { payload });
string key = (string)FM(vm, "GetMethodKey", 1).Invoke(null, new[] { doc });
Console.WriteLine("built key: " + key);

var conv = vq.GetMethods(BindingFlags.Public | BindingFlags.Static).FirstOrDefault(m => m.Name == "Converter" && m.GetParameters().Length == 1);
foreach (var v in new[] { "7.1", "8.1", "9.2" })
{
    object c = conv.Invoke(null, new object[] { v });
    var mfd = c?.GetType().GetProperty("MessageForDeleted")?.GetValue(c) as System.Collections.IDictionary;
    var mnu = c?.GetType().GetProperty("MessageForNoUpgrade")?.GetValue(c) as System.Collections.IDictionary;
    Console.WriteLine($"  v{v}: converter={(c is null ? "NULL" : "ok")} deleted={mfd?.Count ?? -1} containsBuiltKey={mfd?.Contains(key)} noUpgradeContains={mnu?.Contains(key)}");
}

FM(bc, "ClearCurrentEvents", 0)?.Invoke(null, null);
object res = null; string err = null;
try { res = FM(FT("BH.Engine.Serialiser.Convert"), "FromJson", 1).Invoke(null, new object[] { payload }); }
catch (Exception e) { err = (e.InnerException ?? e).Message; }
Console.WriteLine($"\nFromJson result: {(res is null ? "NULL" : res.GetType().Name)}{(err is null ? "" : "  threw: " + err)}");

bool detected = false; int i = 0;
foreach (var e in (FM(bq, "CurrentEvents", 0)?.Invoke(null, null) as System.Collections.IEnumerable) ?? Array.Empty<object>())
{
    i++;
    var m = e.GetType().GetProperty("Message")?.GetValue(e)?.ToString() ?? "";
    if (m.StartsWith("No upgrade for", StringComparison.Ordinal)) detected = true;
    Console.WriteLine($"  event[{i}]: {m.Replace("\n", " | ").Substring(0, Math.Min(150, m.Length))}");
}
Console.WriteLine($"events: {i}");
Console.WriteLine($"detected (\"No upgrade for\") = {detected}   <-- true means FromJson.cs:226 PASSES the item");
