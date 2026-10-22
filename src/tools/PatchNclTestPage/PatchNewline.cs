using Mono.Cecil;
using Mono.Cecil.Cil;
using System;
using System.IO;
using System.Linq;

/// <summary>
/// Makes BC's own line-break choices match a Windows tier (issue #113).
///
/// BC writes Environment.NewLine into error texts, TextBuilder.AppendLine, XML
/// declarations and the like. That is CRLF on Windows and LF on Linux, and the
/// value is a compile-time constant inside CoreLib (R2R), so it cannot be
/// hooked at runtime. The BC call sites are ordinary IL, so they are rewritten
/// on disk:
///
///   call Environment::get_NewLine()          -> ldstr "\r\n"
///   callvirt StringBuilder::AppendLine()     -> ldstr "\r\n"; callvirt Append(string)
///   callvirt StringBuilder::AppendLine(str)  -> callvirt Append(string); ldstr "\r\n"; callvirt Append(string)
///   newobj XmlWriterSettings::.ctor()        -> + dup; ldstr "\r\n"; callvirt set_NewLineChars
///
/// The first one fixes the paired helpers NavDialog.ReplaceBackSlashWithCRLF /
/// ReplaceCRLFWithBackSlash, which turn the `\r\n` stored in the platform
/// resource texts into the `\` markers AL sees. With a bare `\n` the `\r`
/// stayed behind, which is the stray carriage return in 67 corpus tests.
///
/// Idempotent: a second run finds no call left to rewrite.
/// </summary>
static class PatchNewline
{
    const string Crlf = "\r\n";

    /// <summary>
    /// XDocument.Save(Stream, SaveOptions) builds its own XmlWriterSettings inside System.Xml.Linq
    /// (precompiled, so its line break is the constant LF). Same body, with CRLF:
    ///   settings = new() { NewLineChars = "\r\n", Indent = !DisableFormatting,
    ///                      NamespaceHandling |= OmitDuplicates when asked };
    ///   using (var w = XmlWriter.Create(stream, settings)) doc.Save(w);
    /// BC only reaches this call for a document with no declared encoding, so the
    /// declared-encoding branch of the framework method is not needed.
    /// </summary>
    static MethodDefinition AddXDocumentSaveHelper(ModuleDefinition module)
    {
        var holder = module.Types.FirstOrDefault(t => t.Name == "<BcLinuxWindowsText>");
        if (holder == null)
        {
            holder = new TypeDefinition("", "<BcLinuxWindowsText>",
                TypeAttributes.Class | TypeAttributes.Sealed | TypeAttributes.Abstract | TypeAttributes.NotPublic,
                module.TypeSystem.Object);
            module.Types.Add(holder);
        }
        var existing = holder.Methods.FirstOrDefault(m => m.Name == "SaveXDocument");
        if (existing != null) return existing;

        var xdoc = module.ImportReference(typeof(System.Xml.Linq.XDocument));
        var stream = module.ImportReference(typeof(Stream));
        var opts = module.ImportReference(typeof(System.Xml.Linq.SaveOptions));
        var settingsT = module.ImportReference(typeof(System.Xml.XmlWriterSettings));
        var writerT = module.ImportReference(typeof(System.Xml.XmlWriter));

        var m = new MethodDefinition("SaveXDocument",
            MethodAttributes.Static | MethodAttributes.Assembly | MethodAttributes.HideBySig,
            module.TypeSystem.Void);
        m.Parameters.Add(new ParameterDefinition("doc", ParameterAttributes.None, xdoc));
        m.Parameters.Add(new ParameterDefinition("stream", ParameterAttributes.None, stream));
        m.Parameters.Add(new ParameterDefinition("options", ParameterAttributes.None, opts));
        holder.Methods.Add(m);

        var ws = new VariableDefinition(settingsT);
        var w = new VariableDefinition(writerT);
        m.Body.Variables.Add(ws);
        m.Body.Variables.Add(w);
        m.Body.InitLocals = true;

        var il = m.Body.GetILProcessor();
        var ctor = module.ImportReference(typeof(System.Xml.XmlWriterSettings).GetConstructor(Type.EmptyTypes));
        var setNl = module.ImportReference(typeof(System.Xml.XmlWriterSettings).GetProperty("NewLineChars").SetMethod);
        var setIndent = module.ImportReference(typeof(System.Xml.XmlWriterSettings).GetProperty("Indent").SetMethod);
        var setNs = module.ImportReference(typeof(System.Xml.XmlWriterSettings).GetProperty("NamespaceHandling").SetMethod);
        var create = module.ImportReference(typeof(System.Xml.XmlWriter).GetMethod("Create", new[] { typeof(Stream), typeof(System.Xml.XmlWriterSettings) }));
        var save = module.ImportReference(typeof(System.Xml.Linq.XDocument).GetMethod("Save", new[] { typeof(System.Xml.XmlWriter) }));
        var dispose = module.ImportReference(typeof(IDisposable).GetMethod("Dispose"));

        var afterNs = il.Create(OpCodes.Ldarg_1);
        var tryStart = il.Create(OpCodes.Ldarg_0);
        var finallyStart = il.Create(OpCodes.Ldloc, w);
        var skipDispose = il.Create(OpCodes.Endfinally);
        var end = il.Create(OpCodes.Ret);

        il.Append(il.Create(OpCodes.Newobj, ctor));
        il.Append(il.Create(OpCodes.Stloc, ws));
        il.Append(il.Create(OpCodes.Ldloc, ws));
        il.Append(il.Create(OpCodes.Ldstr, Crlf));
        il.Append(il.Create(OpCodes.Callvirt, setNl));
        il.Append(il.Create(OpCodes.Ldloc, ws));
        il.Append(il.Create(OpCodes.Ldarg_2));
        il.Append(il.Create(OpCodes.Ldc_I4_1));
        il.Append(il.Create(OpCodes.And));
        il.Append(il.Create(OpCodes.Ldc_I4_0));
        il.Append(il.Create(OpCodes.Ceq));
        il.Append(il.Create(OpCodes.Callvirt, setIndent));
        il.Append(il.Create(OpCodes.Ldarg_2));
        il.Append(il.Create(OpCodes.Ldc_I4_2));
        il.Append(il.Create(OpCodes.And));
        il.Append(il.Create(OpCodes.Brfalse, afterNs));
        il.Append(il.Create(OpCodes.Ldloc, ws));
        il.Append(il.Create(OpCodes.Ldc_I4_1));
        il.Append(il.Create(OpCodes.Callvirt, setNs));
        il.Append(afterNs);
        il.Append(il.Create(OpCodes.Ldloc, ws));
        il.Append(il.Create(OpCodes.Call, create));
        il.Append(il.Create(OpCodes.Stloc, w));
        il.Append(tryStart);
        il.Append(il.Create(OpCodes.Ldloc, w));
        il.Append(il.Create(OpCodes.Callvirt, save));
        il.Append(il.Create(OpCodes.Leave, end));
        il.Append(finallyStart);
        il.Append(il.Create(OpCodes.Brfalse, skipDispose));
        il.Append(il.Create(OpCodes.Ldloc, w));
        il.Append(il.Create(OpCodes.Callvirt, dispose));
        il.Append(skipDispose);
        il.Append(end);

        m.Body.ExceptionHandlers.Add(new ExceptionHandler(ExceptionHandlerType.Finally)
        {
            TryStart = tryStart,
            TryEnd = finallyStart,
            HandlerStart = finallyStart,
            HandlerEnd = end
        });
        return m;
    }


    /// <summary>
    /// new XmlTextWriter(path, encoding) opens its own StreamWriter inside System.Xml, so its
    /// indentation line break is the framework's LF. Build the StreamWriter here instead:
    ///   new XmlTextWriter(new StreamWriter(path, false, encoding) { NewLine = "\r\n" })
    /// </summary>
    static MethodDefinition AddXmlTextWriterHelper(ModuleDefinition module)
    {
        var holder = module.Types.FirstOrDefault(t => t.Name == "<BcLinuxWindowsText>");
        if (holder == null)
        {
            holder = new TypeDefinition("", "<BcLinuxWindowsText>",
                TypeAttributes.Class | TypeAttributes.Sealed | TypeAttributes.Abstract | TypeAttributes.NotPublic,
                module.TypeSystem.Object);
            module.Types.Add(holder);
        }
        var existing = holder.Methods.FirstOrDefault(x => x.Name == "NewXmlTextWriter");
        if (existing != null) return existing;

        var m = new MethodDefinition("NewXmlTextWriter",
            MethodAttributes.Static | MethodAttributes.Assembly | MethodAttributes.HideBySig,
            module.ImportReference(typeof(System.Xml.XmlTextWriter)));
        m.Parameters.Add(new ParameterDefinition("path", ParameterAttributes.None, module.TypeSystem.String));
        m.Parameters.Add(new ParameterDefinition("encoding", ParameterAttributes.None, module.ImportReference(typeof(System.Text.Encoding))));
        holder.Methods.Add(m);

        var il = m.Body.GetILProcessor();
        var swCtor = module.ImportReference(typeof(System.IO.StreamWriter).GetConstructor(new[] { typeof(string), typeof(bool), typeof(System.Text.Encoding) }));
        var setNl = module.ImportReference(typeof(System.IO.TextWriter).GetProperty("NewLine").SetMethod);
        var xtwCtor = module.ImportReference(typeof(System.Xml.XmlTextWriter).GetConstructor(new[] { typeof(System.IO.TextWriter) }));
        il.Append(il.Create(OpCodes.Ldarg_0));
        il.Append(il.Create(OpCodes.Ldc_I4_0));
        il.Append(il.Create(OpCodes.Ldarg_1));
        il.Append(il.Create(OpCodes.Newobj, swCtor));
        il.Append(il.Create(OpCodes.Dup));
        il.Append(il.Create(OpCodes.Ldstr, Crlf));
        il.Append(il.Create(OpCodes.Callvirt, setNl));
        il.Append(il.Create(OpCodes.Newobj, xtwCtor));
        il.Append(il.Create(OpCodes.Ret));
        return m;
    }

    /// <summary>
    /// Exception.Message text built inside CoreLib ("...\nActual value was -1.") carries the framework's
    /// LF. BC's MapNativeException methods copy it into the AL error text, so route it through
    /// CrlfMessage(e) = e.Message with every line break as CR LF.
    /// </summary>
    static MethodDefinition AddCrlfMessageHelper(ModuleDefinition module)
    {
        var holder = module.Types.FirstOrDefault(t => t.Name == "<BcLinuxWindowsText>");
        if (holder == null)
        {
            holder = new TypeDefinition("", "<BcLinuxWindowsText>",
                TypeAttributes.Class | TypeAttributes.Sealed | TypeAttributes.Abstract | TypeAttributes.NotPublic,
                module.TypeSystem.Object);
            module.Types.Add(holder);
        }
        var existing = holder.Methods.FirstOrDefault(x => x.Name == "CrlfMessage");
        if (existing != null) return existing;

        var m = new MethodDefinition("CrlfMessage",
            MethodAttributes.Static | MethodAttributes.Assembly | MethodAttributes.HideBySig,
            module.TypeSystem.String);
        m.Parameters.Add(new ParameterDefinition("e", ParameterAttributes.None, module.ImportReference(typeof(Exception))));
        holder.Methods.Add(m);

        var il = m.Body.GetILProcessor();
        var getMessage = module.ImportReference(typeof(Exception).GetProperty("Message").GetMethod);
        var replace = module.ImportReference(typeof(string).GetMethod("Replace", new[] { typeof(string), typeof(string) }));
        il.Append(il.Create(OpCodes.Ldarg_0));
        il.Append(il.Create(OpCodes.Callvirt, getMessage));
        il.Append(il.Create(OpCodes.Ldstr, Crlf));
        il.Append(il.Create(OpCodes.Ldstr, "\n"));
        il.Append(il.Create(OpCodes.Callvirt, replace));
        il.Append(il.Create(OpCodes.Ldstr, "\n"));
        il.Append(il.Create(OpCodes.Ldstr, Crlf));
        il.Append(il.Create(OpCodes.Callvirt, replace));
        il.Append(il.Create(OpCodes.Ret));
        return m;
    }

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

            var stringType = module.TypeSystem.String;
            MethodReference sbAppendString = null;
            MethodReference xwsSetNewLineChars = null;

            MethodDefinition saveHelper = null;
            int exMessages = 0;
            int newLines = 0, appendLines = 0, appendLineArgs = 0, writerSettings = 0, xdocSaves = 0, textWriters = 0, xmlTextWriters = 0;
            MethodReference setTextWriterNewLine = null;
            MethodDefinition crlfMessage = null;
            MethodDefinition xmlTextWriterHelper = null;

            foreach (var type in module.GetTypes().ToList())
            {
                if (type.Name == "<BcLinuxWindowsText>") continue;
                foreach (var method in type.Methods)
                {
                    if (!method.HasBody) continue;
                    var il = method.Body.GetILProcessor();
                    bool changed = false;

                    // Snapshot: the loop inserts instructions.
                    foreach (var ins in method.Body.Instructions.ToList())
                    {
                        if (ins.Operand is not MethodReference mr) continue;
                        var owner = mr.DeclaringType?.FullName;

                        if (ins.OpCode.Code is Code.Callvirt or Code.Call
                            && method.Name.StartsWith("MapNativeException") && mr.Name == "get_Message"
                            && owner is "System.Exception" or "System.ArgumentException" or "System.ArgumentOutOfRangeException")
                        {
                            crlfMessage ??= AddCrlfMessageHelper(module);
                            ins.OpCode = OpCodes.Call;
                            ins.Operand = crlfMessage;
                            exMessages++;
                            changed = true;
                            continue;
                        }

                        if (ins.OpCode.Code == Code.Call
                            && owner == "System.Environment" && mr.Name == "get_NewLine")
                        {
                            ins.OpCode = OpCodes.Ldstr;
                            ins.Operand = Crlf;
                            newLines++;
                            changed = true;
                        }
                        else if (ins.OpCode.Code is Code.Callvirt or Code.Call
                            && owner == "System.Text.StringBuilder" && mr.Name == "AppendLine")
                        {
                            sbAppendString ??= module.ImportReference(
                                typeof(System.Text.StringBuilder).GetMethod("Append", new[] { typeof(string) }));

                            if (mr.Parameters.Count == 0)
                            {
                                // [sb] -> [sb, "\r\n"] -> Append. Rewrite the call in place and add the
                                // Append after it, so a branch that targets the call still lands on the
                                // first instruction of the replacement.
                                ins.OpCode = OpCodes.Ldstr;
                                ins.Operand = Crlf;
                                il.InsertAfter(ins, il.Create(OpCodes.Callvirt, sbAppendString));
                                appendLines++;
                                changed = true;
                            }
                            else if (mr.Parameters.Count == 1 && mr.Parameters[0].ParameterType.FullName == "System.String")
                            {
                                // [sb, str] -> Append(str) -> [sb] -> Append("\r\n")
                                ins.OpCode = OpCodes.Callvirt;
                                ins.Operand = sbAppendString;
                                var ldstr = il.Create(OpCodes.Ldstr, Crlf);
                                il.InsertAfter(ins, ldstr);
                                il.InsertAfter(ldstr, il.Create(OpCodes.Callvirt, sbAppendString));
                                appendLineArgs++;
                                changed = true;
                            }
                        }
                        else if (ins.OpCode.Code is Code.Callvirt or Code.Call
                            && owner == "System.Xml.Linq.XDocument" && mr.Name == "Save"
                            && mr.Parameters.Count == 2
                            && mr.Parameters[0].ParameterType.FullName == "System.IO.Stream"
                            && mr.Parameters[1].ParameterType.FullName == "System.Xml.Linq.SaveOptions")
                        {
                            saveHelper ??= AddXDocumentSaveHelper(module);
                            ins.OpCode = OpCodes.Call;
                            ins.Operand = saveHelper;
                            xdocSaves++;
                            changed = true;
                        }
                        else if (ins.OpCode.Code == Code.Newobj
                            && owner is "System.IO.StreamWriter" or "System.IO.StringWriter" && mr.Name == ".ctor")
                        {
                            // StreamWriter/StringWriter take their NewLine from a CoreLib constant (LF).
                            if (ins.Next?.OpCode.Code == Code.Dup && ins.Next.Next?.Operand as string == Crlf)
                                continue;
                            setTextWriterNewLine ??= module.ImportReference(
                                typeof(System.IO.TextWriter).GetProperty("NewLine").SetMethod);
                            var dup = il.Create(OpCodes.Dup);
                            var ldstr = il.Create(OpCodes.Ldstr, Crlf);
                            var set = il.Create(OpCodes.Callvirt, setTextWriterNewLine);
                            il.InsertAfter(ins, dup);
                            il.InsertAfter(dup, ldstr);
                            il.InsertAfter(ldstr, set);
                            textWriters++;
                            changed = true;
                        }
                        else if (ins.OpCode.Code == Code.Newobj
                            && owner == "System.Xml.XmlTextWriter" && mr.Name == ".ctor"
                            && mr.Parameters.Count == 2
                            && mr.Parameters[0].ParameterType.FullName == "System.String"
                            && mr.Parameters[1].ParameterType.FullName == "System.Text.Encoding")
                        {
                            xmlTextWriterHelper ??= AddXmlTextWriterHelper(module);
                            ins.OpCode = OpCodes.Call;
                            ins.Operand = xmlTextWriterHelper;
                            xmlTextWriters++;
                            changed = true;
                        }
                        else if (ins.OpCode.Code == Code.Newobj
                            && owner == "System.Xml.XmlWriterSettings" && mr.Name == ".ctor")
                        {
                            // Already rewritten: newobj; dup; ldstr "\r\n"; callvirt set_NewLineChars
                            if (ins.Next?.OpCode.Code == Code.Dup && ins.Next.Next?.Operand as string == Crlf)
                                continue;
                            xwsSetNewLineChars ??= module.ImportReference(
                                typeof(System.Xml.XmlWriterSettings).GetProperty("NewLineChars").SetMethod);
                            var dup = il.Create(OpCodes.Dup);
                            var ldstr = il.Create(OpCodes.Ldstr, Crlf);
                            var set = il.Create(OpCodes.Callvirt, xwsSetNewLineChars);
                            il.InsertAfter(ins, dup);
                            il.InsertAfter(dup, ldstr);
                            il.InsertAfter(ldstr, set);
                            writerSettings++;
                            changed = true;
                        }
                    }

                    // Inserted instructions can push a short branch out of range.
                    if (changed)
                        IlHelpers.LengthenShortBranches(method.Body);
                }
            }

            Console.WriteLine($"Rewrote {newLines} Environment.NewLine, {appendLines} AppendLine(), " +
                              $"{appendLineArgs} AppendLine(string), {writerSettings} XmlWriterSettings, {xdocSaves} XDocument.Save(Stream), {textWriters} StreamWriter/StringWriter, {xmlTextWriters} XmlTextWriter, {exMessages} MapNativeException messages in {Path.GetFileName(inputPath)}");

            if (newLines + appendLines + appendLineArgs + writerSettings + xdocSaves + textWriters + xmlTextWriters + exMessages == 0)
                return 0;

            if (inputPath == outputPath)
                assembly.Write();
            else
                assembly.Write(outputPath);
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"ERROR: {ex.GetType().Name}: {ex.Message}");
            return 1;
        }
    }
}
