using Mono.Cecil;
using Mono.Cecil.Cil;
using System;
using System.IO;
using System.Linq;

/// <summary>
/// HttpRequestMessage.SetRequestUri / HttpClient.SetBaseAddress with a path that starts
/// with a single "/" (issue #113).
///
/// BC does `new Uri(value)`. On Windows "/api/v1/items" is not a URI and the constructor
/// throws, which AL sees as "Failed to create the URL for the request". On Linux .NET reads
/// a leading "/" as a file path and quietly builds file:///api/v1/items, so the request
/// object accepts it.
///
/// Only the HTTP objects are changed. Other `new Uri` calls in BC build file URIs from real
/// paths on purpose and must keep working. Idempotent: the rewritten calls no longer name Uri.
/// </summary>
static class PatchHttpUri
{
    const string HelperType = "<BcLinuxWindowsText>";
    static readonly string[] Targets = { "NavHttpRequestMessage", "NavHttpClient" };

    public static int Run(string inputPath, string outputPath)
    {
        if (!File.Exists(inputPath))
        {
            Console.WriteLine($"ERROR: {inputPath} not found");
            return 1;
        }
        try
        {
            var resolver = new DefaultAssemblyResolver();
            resolver.AddSearchDirectory(Path.GetDirectoryName(Path.GetFullPath(inputPath)) ?? ".");
            using var assembly = AssemblyDefinition.ReadAssembly(inputPath,
                new ReaderParameters { AssemblyResolver = resolver, ReadWrite = inputPath == outputPath });
            var module = assembly.MainModule;

            MethodDefinition helper = null;
            int rewritten = 0;
            foreach (var type in module.GetTypes().ToList())
            {
                var outer = type;
                while (outer.DeclaringType != null) outer = outer.DeclaringType;
                if (!Targets.Contains(outer.Name)) continue;

                foreach (var method in type.Methods.Where(m => m.HasBody))
                    foreach (var ins in method.Body.Instructions)
                    {
                        if (ins.OpCode.Code != Code.Newobj || ins.Operand is not MethodReference mr) continue;
                        if (mr.DeclaringType?.FullName != "System.Uri" || mr.Name != ".ctor") continue;
                        if (mr.Parameters.Count != 1 || mr.Parameters[0].ParameterType.FullName != "System.String") continue;
                        helper ??= AddHelper(module);
                        ins.OpCode = OpCodes.Call;
                        ins.Operand = helper;
                        rewritten++;
                    }
            }

            Console.WriteLine($"Rewrote {rewritten} new Uri(string) in the HTTP objects of {Path.GetFileName(inputPath)}");
            if (rewritten == 0) return 0;
            if (inputPath == outputPath) assembly.Write(); else assembly.Write(outputPath);
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"ERROR: {ex.GetType().Name}: {ex.Message}");
            return 1;
        }
    }

    static MethodDefinition AddHelper(ModuleDefinition module)
    {
        var holder = module.Types.FirstOrDefault(t => t.Name == HelperType);
        if (holder == null)
        {
            holder = new TypeDefinition("", HelperType,
                TypeAttributes.Class | TypeAttributes.Sealed | TypeAttributes.Abstract | TypeAttributes.NotPublic,
                module.TypeSystem.Object);
            module.Types.Add(holder);
        }
        var existing = holder.Methods.FirstOrDefault(m => m.Name == "NewHttpUri");
        if (existing != null) return existing;

        var m = new MethodDefinition("NewHttpUri",
            MethodAttributes.Static | MethodAttributes.Assembly | MethodAttributes.HideBySig,
            module.ImportReference(typeof(Uri)));
        m.Parameters.Add(new ParameterDefinition("value", ParameterAttributes.None, module.TypeSystem.String));
        holder.Methods.Add(m);

        var il = m.Body.GetILProcessor();
        var isNullOrEmpty = module.ImportReference(typeof(string).GetMethod("IsNullOrEmpty", new[] { typeof(string) }));
        var getChars = module.ImportReference(typeof(string).GetMethod("get_Chars", new[] { typeof(int) }));
        var getLength = module.ImportReference(typeof(string).GetMethod("get_Length"));
        var uriCtor = module.ImportReference(typeof(Uri).GetConstructor(new[] { typeof(string) }));
        var ufeCtor = module.ImportReference(typeof(UriFormatException).GetConstructor(new[] { typeof(string) }));

        var normal = il.Create(OpCodes.Ldarg_0);
        il.Append(il.Create(OpCodes.Ldarg_0));
        il.Append(il.Create(OpCodes.Call, isNullOrEmpty));
        il.Append(il.Create(OpCodes.Brtrue, normal));
        il.Append(il.Create(OpCodes.Ldarg_0));
        il.Append(il.Create(OpCodes.Ldc_I4_0));
        il.Append(il.Create(OpCodes.Callvirt, getChars));
        il.Append(il.Create(OpCodes.Ldc_I4, (int)'/'));
        il.Append(il.Create(OpCodes.Bne_Un, normal));
        // "//host/path" is a UNC-style file URI on both platforms; only a single "/" is a bare path.
        var refuse = il.Create(OpCodes.Ldstr, "Invalid URI: The format of the URI could not be determined.");
        il.Append(il.Create(OpCodes.Ldarg_0));
        il.Append(il.Create(OpCodes.Callvirt, getLength));
        il.Append(il.Create(OpCodes.Ldc_I4_1));
        il.Append(il.Create(OpCodes.Ble, refuse));
        il.Append(il.Create(OpCodes.Ldarg_0));
        il.Append(il.Create(OpCodes.Ldc_I4_1));
        il.Append(il.Create(OpCodes.Callvirt, getChars));
        il.Append(il.Create(OpCodes.Ldc_I4, (int)'/'));
        il.Append(il.Create(OpCodes.Beq, normal));
        il.Append(refuse);
        il.Append(il.Create(OpCodes.Newobj, ufeCtor));
        il.Append(il.Create(OpCodes.Throw));
        il.Append(normal);
        il.Append(il.Create(OpCodes.Newobj, uriCtor));
        il.Append(il.Create(OpCodes.Ret));
        return m;
    }
}
