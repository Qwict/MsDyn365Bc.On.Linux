/// <summary>
/// Cleans up what Test Runner Extension 3.x stored for coverage and 4.0 no longer uses:
/// the "Coverage Line" records and the CSV blob of "Coverage Setup". Both are obsolete
/// rather than removed, because dropping a table or field is a destructive schema change
/// for a tenant that upgrades in place, so the data is emptied instead. Both tables are
/// per company, hence the per company trigger. Safe to run again: with nothing left it
/// does nothing.
/// </summary>
codeunit 99917 "Coverage Upgrade"
{
    Subtype = Upgrade;
    Permissions = tabledata "Coverage Line" = rd,
                  tabledata "Coverage Setup" = rm;

    trigger OnUpgradePerCompany()
    begin
        DeleteObsoleteLines();
        ClearObsoleteBlob();
    end;

#pragma warning disable AL0432
    local procedure DeleteObsoleteLines()
    var
        CoverageLine: Record "Coverage Line";
    begin
        if not CoverageLine.IsEmpty() then
            CoverageLine.DeleteAll();
    end;

    local procedure ClearObsoleteBlob()
    var
        CoverageSetup: Record "Coverage Setup";
    begin
        if not CoverageSetup.Get() then
            exit;
        CoverageSetup.CalcFields(Coverage);
        if not CoverageSetup.Coverage.HasValue() then
            exit;
        Clear(CoverageSetup.Coverage);
        CoverageSetup.Modify();
    end;
#pragma warning restore AL0432
}
