using Mono.Cecil;
using Mono.Cecil.Cil;
using System;
using System.Collections.Generic;
using System.Linq;

/// <summary>
/// Copies a helper class written in plain C# (BcLinuxCulture.cs) into a
/// target assembly. Cecil reads the patcher's own DLL and clones the IL of every method of the
/// class into the shared holder type, so BC's code can call it without a new assembly reference.
///
/// The source class has to be self-contained: static methods that call only the framework, no
/// lambdas, closures, static fields or try/catch (nothing a plain IL copy carries over). The
/// root method keeps its name; every other method is copied as "&lt;Class&gt;_&lt;Method&gt;".
/// </summary>
static class HelperCloner
{
    public const string HolderType = "<BcLinuxWindowsText>";

    public static TypeDefinition Holder(ModuleDefinition target)
    {
        var holder = target.Types.FirstOrDefault(t => t.Name == HolderType);
        if (holder == null)
        {
            holder = new TypeDefinition("", HolderType,
                TypeAttributes.Class | TypeAttributes.Sealed | TypeAttributes.Abstract | TypeAttributes.NotPublic,
                target.TypeSystem.Object);
            target.Types.Add(holder);
        }
        return holder;
    }

    /// <summary>Copy <paramref name="sourceClass"/> into the target; return the root method (already there on a second call).</summary>
    public static MethodDefinition Clone(ModuleDefinition target, string sourceClass, string rootMethod)
    {
        var holder = Holder(target);
        var existing = holder.Methods.FirstOrDefault(m => m.Name == rootMethod);
        if (existing != null) return existing;

        using var selfAssembly = AssemblyDefinition.ReadAssembly(typeof(HelperCloner).Assembly.Location);
        var srcType = selfAssembly.MainModule.GetType(sourceClass)
            ?? throw new InvalidOperationException($"{sourceClass} not found in the patcher assembly");

        // Pass 1: signatures.
        var map = new Dictionary<MethodDefinition, MethodDefinition>();
        foreach (var sm in srcType.Methods.Where(m => !m.IsConstructor && m.HasBody))
        {
            var nm = new MethodDefinition(sm.Name == rootMethod ? rootMethod : sourceClass + "_" + sm.Name,
                MethodAttributes.Static | MethodAttributes.Assembly | MethodAttributes.HideBySig,
                target.ImportReference(sm.ReturnType));
            foreach (var p in sm.Parameters)
                nm.Parameters.Add(new ParameterDefinition(p.Name, p.Attributes, target.ImportReference(p.ParameterType)));
            holder.Methods.Add(nm);
            map[sm] = nm;
        }

        // Pass 2: bodies.
        foreach (var (sm, nm) in map)
        {
            var vars = new Dictionary<VariableDefinition, VariableDefinition>();
            foreach (var v in sm.Body.Variables)
            {
                var nv = new VariableDefinition(target.ImportReference(v.VariableType));
                nm.Body.Variables.Add(nv);
                vars[v] = nv;
            }
            nm.Body.InitLocals = sm.Body.InitLocals;

            var il = nm.Body.GetILProcessor();
            var copies = new Dictionary<Instruction, Instruction>();
            foreach (var si in sm.Body.Instructions)
            {
                Instruction ni = si.Operand switch
                {
                    null => il.Create(si.OpCode),
                    MethodReference mr => il.Create(si.OpCode, MapMethod(mr, srcType, map, target)),
                    TypeReference tr => il.Create(si.OpCode, target.ImportReference(tr)),
                    FieldReference fr => il.Create(si.OpCode, target.ImportReference(fr)),
                    VariableDefinition vd => il.Create(si.OpCode, vars[vd]),
                    ParameterDefinition pd => il.Create(si.OpCode, nm.Parameters[pd.Index]),
                    string s => il.Create(si.OpCode, s),
                    int i => il.Create(si.OpCode, i),
                    sbyte sb => il.Create(si.OpCode, sb),
                    byte b => il.Create(si.OpCode, b),
                    long l => il.Create(si.OpCode, l),
                    float f => il.Create(si.OpCode, f),
                    double dd => il.Create(si.OpCode, dd),
                    Instruction or Instruction[] => NewBranch(il, si.OpCode), // target set below
                    _ => throw new NotSupportedException($"operand {si.Operand.GetType().Name} in {sm.Name}")
                };
                il.Append(ni);
                copies[si] = ni;
            }
            for (int k = 0; k < sm.Body.Instructions.Count; k++)
            {
                var so = sm.Body.Instructions[k].Operand;
                if (so is Instruction t) copies[sm.Body.Instructions[k]].Operand = copies[t];
                else if (so is Instruction[] ts) copies[sm.Body.Instructions[k]].Operand = ts.Select(x => copies[x]).ToArray();
            }
            if (sm.Body.HasExceptionHandlers)
                throw new NotSupportedException($"{sm.Name}: exception handlers are not copied");
        }
        return map.First(kv => kv.Key.Name == rootMethod).Value;
    }

    /// <summary>Cecil refuses a branch without a target, so start from a Nop and retype it.</summary>
    static Instruction NewBranch(ILProcessor il, OpCode opCode)
    {
        var ins = il.Create(OpCodes.Nop);
        ins.OpCode = opCode;
        return ins;
    }

    static MethodReference MapMethod(MethodReference mr, TypeDefinition srcType,
        Dictionary<MethodDefinition, MethodDefinition> map, ModuleDefinition target)
    {
        if (mr.DeclaringType.FullName == srcType.FullName)
        {
            var def = mr.Resolve();
            if (def != null && map.TryGetValue(def, out var nm)) return nm;
        }
        return target.ImportReference(mr);
    }
}
