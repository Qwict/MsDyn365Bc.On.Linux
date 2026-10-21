/// <summary>
/// Names objects the way AL source does: Codeunit, TableExtension, ...
///
/// Format() of an object type option is localized ("Tabel" on a Dutch server), and so is
/// the same text read back by another tool. The ordinal never changes, so every object
/// type this extension writes goes through here: the platform ordinal in, the AL keyword
/// out. Also builds the "type,id" key the coverage code uses to look an object up.
/// </summary>
codeunit 99914 "Coverage Object Type"
{
    /// <summary>
    /// The AL keyword for a platform object type ordinal. An ordinal this extension does
    /// not know becomes 'Object' + ordinal, so a new platform type is still told apart.
    /// </summary>
    procedure Keyword(Ordinal: Integer): Text
    begin
        case Ordinal of
            1:
                exit('Table');
            3:
                exit('Report');
            5:
                exit('Codeunit');
            6:
                exit('XMLport');
            8:
                exit('Page');
            9:
                exit('Query');
            14:
                exit('PageExtension');
            15:
                exit('TableExtension');
            22:
                exit('ReportExtension');
            else
                exit('Object' + Format(Ordinal, 0, 9));
        end;
    end;

    /// <summary>
    /// The key of an object in the coverage code: keyword, comma, ID ("Codeunit,50100").
    /// </summary>
    procedure ObjectKey(Ordinal: Integer; ObjectId: Integer): Text
    begin
        exit(Keyword(Ordinal) + ',' + Format(ObjectId, 0, 9));
    end;
}
