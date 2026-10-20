/// <summary>
/// The recorded coverage of the current run: CSV lines object_type,object_id,line_no,hits
/// (UTF-8, no header) in "Coverage Setup".Coverage. One blob instead of one record per
/// line, because BC writes and reads a large app's 120,000 lines one record at a time.
/// </summary>
codeunit 99911 "Coverage Store"
{
    Permissions = tabledata "Coverage Setup" = rm;

    procedure Save(Csv: Text)
    var
        CoverageSetup: Record "Coverage Setup";
        OutStr: OutStream;
    begin
        if not CoverageSetup.Get() then
            exit;
        CoverageSetup.Coverage.CreateOutStream(OutStr, TextEncoding::UTF8);
        OutStr.WriteText(Csv);
        CoverageSetup.Modify();
    end;

    procedure Read(): Text
    var
        CoverageSetup: Record "Coverage Setup";
        InStr: InStream;
        Csv: TextBuilder;
        Line: Text;
    begin
        if not CoverageSetup.Get() then
            exit('');
        CoverageSetup.CalcFields(Coverage);
        if not CoverageSetup.Coverage.HasValue() then
            exit('');
        CoverageSetup.Coverage.CreateInStream(InStr, TextEncoding::UTF8);
        while not InStr.EOS() do begin
            InStr.ReadText(Line);
            Csv.AppendLine(Line);
        end;
        exit(Csv.ToText());
    end;

    /// <summary>
    /// The stored hits by line key, the CSV line without its hits: object_type,object_id,line_no.
    /// </summary>
    procedure LoadHits(var Hits: Dictionary of [Text, Integer])
    var
        CoverageSetup: Record "Coverage Setup";
        InStr: InStream;
        Line: Text;
        Separator: Integer;
        LineHits: Integer;
    begin
        Clear(Hits);
        if not CoverageSetup.Get() then
            exit;
        CoverageSetup.CalcFields(Coverage);
        if not CoverageSetup.Coverage.HasValue() then
            exit;
        CoverageSetup.Coverage.CreateInStream(InStr, TextEncoding::UTF8);
        while not InStr.EOS() do begin
            InStr.ReadText(Line);
            Separator := Line.LastIndexOf(',');
            if (Separator > 1) and Evaluate(LineHits, Line.Substring(Separator + 1), 9) then
                Hits.Set(Line.Substring(1, Separator - 1), LineHits);
        end;
    end;

    /// <summary>
    /// The stored lines as "Coverage Line" records, for the codeCoverageLines page.
    /// </summary>
    procedure FillLines(var TempCoverageLine: Record "Coverage Line" temporary)
    var
        Hits: Dictionary of [Text, Integer];
        LineKey: Text;
        Parts: List of [Text];
    begin
        TempCoverageLine.Reset();
        TempCoverageLine.DeleteAll();
        LoadHits(Hits);
        foreach LineKey in Hits.Keys() do begin
            Parts := LineKey.Split(',');
            if Parts.Count() = 3 then begin
                TempCoverageLine.Init();
                TempCoverageLine."Object Type" := CopyStr(Parts.Get(1), 1, MaxStrLen(TempCoverageLine."Object Type"));
                if Evaluate(TempCoverageLine."Object ID", Parts.Get(2), 9) and Evaluate(TempCoverageLine."Line No.", Parts.Get(3), 9) then begin
                    TempCoverageLine.Hits := Hits.Get(LineKey);
                    if TempCoverageLine.Insert() then;
                end;
            end;
        end;
    end;
}
