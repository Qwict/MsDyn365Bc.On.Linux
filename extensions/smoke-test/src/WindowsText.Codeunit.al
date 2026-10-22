// Regression guard for issue #113: text behaviour that a Windows tier has and a Linux
// one did not.
//
// A corpus run against an official Microsoft Windows container showed 219 tests that
// disagree with this tier for reasons that come from the platform, not the harness.
// Most of them trace to a few constants that .NET bakes in at compile time:
//
//  * Environment.NewLine is LF on Linux and CRLF on Windows. BC writes it into the
//    platform error texts (as the `\` line-break marker AL sees), TextBuilder.AppendLine,
//    XML, YAML and CSV output. Rewritten in BC's own IL by `PatchNclTestPage newline`.
//  * Encoding.GetEncoding(0), the ANSI code page, is windows-1252 on Windows and UTF-8
//    here, which put TextEncoding::Windows, MSDos and the default encoding on UTF-8. The
//    OEM tables behind MSDos were identity mappings. `PatchNclTestPage encoding` and the
//    code page 437 tables in kernel32_stubs.c.
//  * ICU writes a narrow no-break space before AM/PM; Windows' NLS data a plain space.
//    `PatchNclTestPage culture`.
//
// Every expected value below is what the Windows container reported, taken from the
// corpus run's failure messages. If one of these fails, a patch stopped applying — check
// the entrypoint's "Patched ... Windows text behaviour" lines and the service volume stamp.
codeunit 70010 "BC Linux Windows Text Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure PlatformErrorTextHasNoCarriageReturn()
    var
        D: Date;
        Msg: Text;
        I: Integer;
    begin
        // The resource text holds real CRLFs; AL sees each as one `\`. A stray CR in front of
        // the `\` was the Linux result.
        asserterror Evaluate(D, 'x');
        Msg := GetLastErrorText();
        for I := 1 to StrLen(Msg) do
            LibraryAssert.AreNotEqual(13, Msg[I], 'carriage return at position ' + Format(I));
        LibraryAssert.IsTrue(StrPos(Msg, '.\\Make sure') > 0, 'line break marker is \\');
    end;

    [Test]
    procedure FrameworkErrorTextUsesTheLineBreakMarker()
    var
        T: Text;
        Msg: Text;
        I: Integer;
    begin
        // The framework writes "... (Parameter 'startIndex')<LF>Actual value was -1." with a bare
        // LF; a Windows tier has CR LF there, and BC turns that into the `\` marker.
        T := 'abc';
        asserterror T := T.Substring(0);
        Msg := GetLastErrorText();
        LibraryAssert.IsTrue(StrPos(Msg, '\Actual value was') > 0, 'marker in: ' + Msg);
        for I := 1 to StrLen(Msg) do
            LibraryAssert.AreNotEqual(10, Msg[I], 'line feed at position ' + Format(I));
    end;

    [Test]
    procedure TextBuilderAppendLineIsCrLf()
    var
        TB: TextBuilder;
        T: Text;
    begin
        TB.AppendLine('a');
        T := TB.ToText();
        LibraryAssert.AreEqual(3, StrLen(T), 'a + CR + LF');
        LibraryAssert.AreEqual(13, T[2], 'CR');
        LibraryAssert.AreEqual(10, T[3], 'LF');
    end;

    [Test]
    procedure XmlTextUsesCrLf()
    var
        Doc: XmlDocument;
        T: Text;
    begin
        // JsonObject.WriteToYaml is also CR LF now, but it needs runtime 14.3 and this app
        // has to load on BC 27.0, so the corpus covers it.
        XmlDocument.ReadFrom('<r><a>1</a></r>', Doc);
        Doc.WriteTo(T);
        LibraryAssert.IsTrue(StrPos(T, '?>' + CrLf() + '<r>') > 0, 'XML declaration is followed by CR LF');
    end;

    [Test]
    procedure XmlWrittenToAStreamUsesCrLf()
    var
        Blob: Record "BC Linux Windows Text Blob";
        Doc: XmlDocument;
        OutS: OutStream;
        InS: InStream;
        B: Byte;
        Previous: Integer;
        CrLfFound: Boolean;
    begin
        // XDocument.Save(Stream) builds its own writer settings inside the framework, so it
        // wrote a bare LF. ReadText would hide the difference (it splits on either), so look at
        // the bytes.
        Doc := XmlDocument.Create();
        Doc.Add(XmlElement.Create('r'));
        Blob.Data.CreateOutStream(OutS);
        Doc.WriteTo(OutS);
        Blob.Insert();
        Blob.CalcFields(Data);
        Blob.Data.CreateInStream(InS);
        while not InS.EOS() do begin
            InS.Read(B);
            if (B = 10) and (Previous = 13) then
                CrLfFound := true;
            Previous := B;
        end;
        LibraryAssert.IsTrue(CrLfFound, 'a CR LF pair between the declaration and the root');
    end;

    [Test]
    procedure MsDosEncodingUsesCodePage437()
    var
        Bytes: Text;
    begin
        // e-acute is E9 in windows-1252 and 82 in code page 437. The euro sign is not in 437;
        // 437's own table and BC's pairing fix-up put it at B1 on a Windows tier.
        Bytes := BytesOf('é€', TextEncoding::MSDos);
        LibraryAssert.AreEqual('82B1', Bytes, 'MSDos');
        Bytes := BytesOf('é€', TextEncoding::Windows);
        LibraryAssert.AreEqual('E980', Bytes, 'Windows is windows-1252');
        Bytes := BytesOf('é', TextEncoding::UTF8);
        LibraryAssert.AreEqual('C3A9', Bytes, 'UTF8');
    end;

    [Test]
    procedure TimeFormatHasAPlainSpaceBeforeAmPm()
    var
        T: Time;
        Formatted: Text;
        I: Integer;
    begin
        T := 143005T;
        Formatted := Format(T, 0, 0);
        for I := 1 to StrLen(Formatted) do
            LibraryAssert.AreNotEqual(8239, Formatted[I], 'narrow no-break space at ' + Format(I) + ' in "' + Formatted + '"');
    end;

    [Test]
    procedure HttpRequestUriMustHaveAScheme()
    var
        Request: HttpRequestMessage;
    begin
        // A leading "/" is not a URI on Windows. .NET on Linux read it as a file path and
        // built file:///api/v1/items.
        LibraryAssert.IsFalse(Request.SetRequestUri('/api/v1/items'), 'relative path is refused');
        LibraryAssert.IsTrue(Request.SetRequestUri('https://example.com/api'), 'absolute URL is accepted');
        LibraryAssert.IsTrue(Request.SetRequestUri('//host/path'), 'a UNC-style path is a URI on both platforms');
    end;

    local procedure CrLf() Result: Text
    begin
        Result[1] := 13;
        Result[2] := 10;
    end;

    local procedure BytesOf(Value: Text; Encoding: TextEncoding) Hex: Text
    var
        Blob: Record "BC Linux Windows Text Blob";
        OutS: OutStream;
        InS: InStream;
        B: Byte;
        Digits: Text;
    begin
        Digits := '0123456789ABCDEF';
        Blob.Data.CreateOutStream(OutS, Encoding);
        OutS.WriteText(Value);
        Blob.Id := 1;
        if not Blob.Insert() then
            Blob.Modify();
        Blob.CalcFields(Data);
        Blob.Data.CreateInStream(InS);
        while not InS.EOS() do begin
            InS.Read(B);
            Hex += CopyStr(Digits, (B div 16) + 1, 1) + CopyStr(Digits, (B mod 16) + 1, 1);
        end;
    end;

    [Test]
    procedure QueryCsvDateTimeUsesAPlainSpaceBeforeAmPm()
    var
        Row: Record "BC Linux Windows Text Blob";
        Holder: Record "BC Linux Windows Text Blob";
        Q: Query "BC Linux Windows Text Query";
        OutS: OutStream;
        InS: InStream;
        Line: Text;
        I: Integer;
    begin
        // Issue #120: SaveAsCsv formats with the thread's default culture, which no BC code
        // sets on a pool thread, so it was still the ICU en-US with U+202F before AM/PM.
        Row.DeleteAll();
        Row.Id := 1;
        Row.Stamp := CreateDateTime(DMY2Date(5, 3, 2024), 143005T);
        Row.Insert();

        Holder.Id := 2;
        Holder.Data.CreateOutStream(OutS);
        Holder.Insert();
        LibraryAssert.IsTrue(Q.SaveAsCsv(OutS), 'SaveAsCsv');
        Holder.Modify();
        Holder.CalcFields(Data);
        Holder.Data.CreateInStream(InS);
        InS.ReadText(Line);
        InS.ReadText(Line);

        LibraryAssert.IsTrue((StrPos(Line, ' AM') > 0) or (StrPos(Line, ' PM') > 0), 'plain space before AM/PM in: ' + Line);
        for I := 1 to StrLen(Line) do
            LibraryAssert.AreNotEqual(8239, Line[I], 'narrow no-break space at position ' + Format(I));
        Row.DeleteAll();
    end;
}
