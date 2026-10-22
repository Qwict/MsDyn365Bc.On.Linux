using Mono.Cecil;
using Mono.Cecil.Cil;
using System;
using System.IO;
using System.Linq;
using System.Text;

/// <summary>
/// Gives BC the ANSI code page a Windows tier has (issue #113).
///
/// BC asks for the machine's ANSI code page with Encoding.GetEncoding(0).
/// That is windows-1252 on a Windows tier and UTF-8 on Linux, which is why
/// TextEncoding::Windows and the default encoding came out as UTF-8 here
/// (Base64 Convert, WriteText, ReadText, xmlport).
///
/// Every call to Encoding.GetEncoding(int) is redirected to a helper added to
/// the same assembly that treats 0 as 1252 and passes any other number on.
/// A helper in the target assembly means no new assembly reference and no
/// instruction to retarget a branch around. Idempotent: the redirected calls
/// no longer name Encoding.GetEncoding.
/// </summary>
static class PatchEncoding
{
    const int AnsiCodePage = 1252;
    const string HelperType = "<BcLinuxWindowsText>";

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
            var readerParams = new ReaderParameters
            {
                AssemblyResolver = resolver,
                ReadWrite = inputPath == outputPath
            };
            using var assembly = AssemblyDefinition.ReadAssembly(inputPath, readerParams);
            var module = assembly.MainModule;

            MethodReference getEncoding = module.ImportReference(
                typeof(Encoding).GetMethod("GetEncoding", new[] { typeof(int) }));

            MethodDefinition helper = null;
            int redirected = 0;

            foreach (var type in module.GetTypes().ToList())
            {
                if (type.Name == HelperType) continue;
                foreach (var method in type.Methods)
                {
                    if (!method.HasBody) continue;
                    foreach (var ins in method.Body.Instructions)
                    {
                        if (ins.OpCode.Code != Code.Call || ins.Operand is not MethodReference mr) continue;
                        if (mr.DeclaringType?.FullName != "System.Text.Encoding" || mr.Name != "GetEncoding") continue;
                        if (mr.Parameters.Count != 1 || mr.Parameters[0].ParameterType.FullName != "System.Int32") continue;

                        helper ??= AddHelper(module, getEncoding);
                        ins.Operand = helper;
                        redirected++;
                    }
                }
            }

            Console.WriteLine($"Redirected {redirected} Encoding.GetEncoding(int) calls in {Path.GetFileName(inputPath)}");
            if (redirected == 0) return 0;

            if (inputPath == outputPath) assembly.Write();
            else assembly.Write(outputPath);
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"ERROR: {ex.GetType().Name}: {ex.Message}");
            return 1;
        }
    }

    static MethodDefinition AddHelper(ModuleDefinition module, MethodReference getEncoding)
    {
        // PatchNewline adds its own helper to the same holder type.
        var holder = module.Types.FirstOrDefault(t => t.Name == HelperType);
        if (holder == null)
        {
            holder = new TypeDefinition("", HelperType,
                TypeAttributes.Class | TypeAttributes.Sealed | TypeAttributes.Abstract | TypeAttributes.NotPublic,
                module.TypeSystem.Object);
            module.Types.Add(holder);
        }

        var helper = new MethodDefinition("GetEncoding",
            MethodAttributes.Static | MethodAttributes.Assembly | MethodAttributes.HideBySig,
            module.ImportReference(typeof(Encoding)));
        helper.Parameters.Add(new ParameterDefinition("codepage", ParameterAttributes.None, module.TypeSystem.Int32));
        holder.Methods.Add(helper);

        var il = helper.Body.GetILProcessor();
        var call = il.Create(OpCodes.Ldarg_0);
        il.Append(il.Create(OpCodes.Ldarg_0));
        il.Append(il.Create(OpCodes.Brtrue, call));
        il.Append(il.Create(OpCodes.Ldc_I4, AnsiCodePage));
        il.Append(il.Create(OpCodes.Starg, helper.Parameters[0]));
        il.Append(call);
        il.Append(il.Create(OpCodes.Call, getEncoding));
        il.Append(il.Create(OpCodes.Ret));
        return helper;
    }
}
