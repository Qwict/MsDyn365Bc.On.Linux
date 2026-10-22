using Mono.Cecil.Cil;

/// <summary>
/// Helpers shared by the Cecil patches that insert instructions into existing methods.
/// </summary>
static class IlHelpers
{
    /// <summary>
    /// Turn every short-form branch into its long form. Inserting an instruction can push a
    /// target past what a one-byte offset reaches, and Cecil writes the truncated offset without
    /// complaint: the branch then lands on the wrong instruction and the JIT reports a stack
    /// underflow or InvalidProgramException far from the cause. Call this on every method body
    /// that was grown.
    /// </summary>
    public static void LengthenShortBranches(MethodBody body)
    {
        foreach (var ins in body.Instructions)
        {
            var longForm = ins.OpCode.Code switch
            {
                Code.Br_S => OpCodes.Br,
                Code.Brfalse_S => OpCodes.Brfalse,
                Code.Brtrue_S => OpCodes.Brtrue,
                Code.Beq_S => OpCodes.Beq,
                Code.Bge_S => OpCodes.Bge,
                Code.Bgt_S => OpCodes.Bgt,
                Code.Ble_S => OpCodes.Ble,
                Code.Blt_S => OpCodes.Blt,
                Code.Bne_Un_S => OpCodes.Bne_Un,
                Code.Bge_Un_S => OpCodes.Bge_Un,
                Code.Bgt_Un_S => OpCodes.Bgt_Un,
                Code.Ble_Un_S => OpCodes.Ble_Un,
                Code.Blt_Un_S => OpCodes.Blt_Un,
                Code.Leave_S => OpCodes.Leave,
                _ => default
            };
            if (longForm != default) ins.OpCode = longForm;
        }
    }
}
