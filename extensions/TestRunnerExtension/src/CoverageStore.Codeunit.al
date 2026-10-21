/// <summary>
/// The recorded coverage of the current run: the report text of "Coverage Report Builder"
/// (UTF-8) in "Coverage Setup".Report. One blob instead of one record per line, because
/// BC writes and reads a large app's 120,000 lines one record at a time.
///
/// The legacy CSV (object_type,object_id,line_no,hits, no header) that older run-tests.sh
/// versions read is not stored a second time; it is cut out of the report when asked for.
/// </summary>
codeunit 99911 "Coverage Store"
{
    Permissions = tabledata "Coverage Setup" = rm;

    /// <summary>
    /// Stores the report and what the Builder counted in it. Nothing is stored when no
    /// run was started.
    /// </summary>
    procedure Save(Report: Text; Complete: Boolean; var Builder: Codeunit "Coverage Report Builder")
    var
        CoverageSetup: Record "Coverage Setup";
        OutStr: OutStream;
    begin
        if not CoverageSetup.Get() then
            exit;
        CoverageSetup.Report.CreateOutStream(OutStr, TextEncoding::UTF8);
        OutStr.WriteText(Report);
        CoverageSetup.Complete := Complete;
        Builder.GetCounts(CoverageSetup.Objects, CoverageSetup.Lines, CoverageSetup."Covered Lines", CoverageSetup."Unmeasured Objects");
        CoverageSetup.Modify();
    end;

    /// <summary>
    /// The stored report with a line feed after every record, whatever the host's own line break.
    /// </summary>
    procedure ReadReport(): Text
    var
        CoverageSetup: Record "Coverage Setup";
        InStr: InStream;
        Report: TextBuilder;
        Line: Text;
    begin
        if not CoverageSetup.Get() then
            exit('');
        CoverageSetup.CalcFields(Report);
        if not CoverageSetup.Report.HasValue() then
            exit('');
        CoverageSetup.Report.CreateInStream(InStr, TextEncoding::UTF8);
        while not InStr.EOS() do begin
            InStr.ReadText(Line);
            Report.Append(Line + NewLine());
        end;
        exit(Report.ToText());
    end;

    /// <summary>
    /// The legacy CSV of a report: object_type,object_id,line_no,hits per Code line.
    /// </summary>
    procedure CsvFromReport(Report: Text): Text
    var
        Csv: TextBuilder;
        Line: Text;
        Parts: List of [Text];
    begin
        foreach Line in Report.Split(NewLine()) do
            if Line.StartsWith('L,') then begin
                Parts := Line.Split(',');
                if Parts.Count() = 6 then
                    Csv.AppendLine(Parts.Get(2) + ',' + Parts.Get(3) + ',' + Parts.Get(4) + ',' + Parts.Get(5));
            end;
        exit(Csv.ToText());
    end;

    /// <summary>
    /// The stored lines and functions by line key ("type,id,line"), to continue a run in
    /// a new session. A line's value is "hits,partial"; a function's is "executed,signature"
    /// with the signature as stored (quoted).
    /// </summary>
    procedure LoadBase(var BaseLines: Dictionary of [Text, Text]; var BaseFunctions: Dictionary of [Text, Text])
    var
        CoverageSetup: Record "Coverage Setup";
        InStr: InStream;
        Line: Text;
    begin
        Clear(BaseLines);
        Clear(BaseFunctions);
        if not CoverageSetup.Get() then
            exit;
        CoverageSetup.CalcFields(Report);
        if not CoverageSetup.Report.HasValue() then
            exit;
        CoverageSetup.Report.CreateInStream(InStr, TextEncoding::UTF8);
        while not InStr.EOS() do begin
            InStr.ReadText(Line);
            LoadRecord(Line, BaseLines, BaseFunctions);
        end;
    end;

    local procedure LoadRecord(Line: Text; var BaseLines: Dictionary of [Text, Text]; var BaseFunctions: Dictionary of [Text, Text])
    var
        Parts: List of [Text];
        LineKey: Text;
    begin
        if not (Line.StartsWith('L,') or Line.StartsWith('F,')) then
            exit;
        Parts := Line.Split(',');
        if Parts.Count() < 6 then
            exit;
        LineKey := Parts.Get(2) + ',' + Parts.Get(3) + ',' + Parts.Get(4);
        if Line.StartsWith('L,') then
            BaseLines.Set(LineKey, Parts.Get(5) + ',' + Parts.Get(6))
        else
            // The signature is the rest of the record and may hold commas itself.
            BaseFunctions.Set(LineKey, Parts.Get(5) + ',' + Line.Substring(StrLen('F,' + LineKey + ',' + Parts.Get(5) + ',') + 1));
    end;

    local procedure NewLine(): Text
    var
        LineFeed: Text[1];
    begin
        LineFeed[1] := 10;
        exit(LineFeed);
    end;
}
