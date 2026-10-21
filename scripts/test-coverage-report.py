#!/usr/bin/env python3
"""Tests for scripts/coverage_report.py: the v2 report parser, the .al source
mapping and the legacy CSV, Cobertura and LCOV writers.

The writers feed other people's tools (Azure DevOps, GitLab, ReportGenerator)
and the control plane, so the tests pin the exact bytes of the CSV and parse the
Cobertura XML back rather than eyeballing strings. No BC, no network:

    python3 scripts/test-coverage-report.py
"""

import os
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import coverage_report as cr  # noqa: E402

APP1 = "11111111-1111-1111-1111-111111111111"
APP2 = "22222222-2222-2222-2222-222222222222"

REPORT = "\n".join([
    "M,version,2",
    "M,complete,1",
    f"A,{APP1},My App,Contoso,1.0.0.0",
    f"A,{APP2},Other App,Contoso,2.0.0.0",
    f"O,Codeunit,50100,{APP1},1",
    f"O,Codeunit,50102,{APP1},1",
    f"O,TableExtension,50110,{APP1},1",
    f"O,Codeunit,50200,{APP2},1",
    f"O,PageExtension,50201,{APP2},0",
    "L,Codeunit,50100,5,3,0",
    "L,Codeunit,50100,6,0,0",
    "L,Codeunit,50100,7,1,1",
    "F,Codeunit,50100,3,1,procedure Foo()",
    'F,Codeunit,50100,9,0,"local procedure Bar(a: Integer, b: Text)"',
    "L,Codeunit,50102,3,2,0",
    "F,Codeunit,50102,2,1,trigger OnRun()",
    "L,TableExtension,50110,4,0,0",
    "F,TableExtension,50110,2,0,procedure Baz()",
    "L,Codeunit,50200,4,5,0",
    "F,Codeunit,50200,2,1,procedure Qux()",
    "X,FutureRecord,1,2,3",
    "",
])

AL_OPS = """namespace Contoso.Ops;

using System.Utilities;

// codeunit 99999 "Commented Out"
codeunit 50100 "My Codeunit"
{
    /* codeunit 88888 "Also Commented" */
    var
        Text: Text;

    procedure Foo()
    begin
        Text := 'codeunit 77777 "In String" { ';
    end;
}

codeunit 50102 Second
{
    trigger OnRun()
    begin
    end;
}
"""

AL_EXT = """tableextension 50110 "Cust Ext" extends Customer
{
    procedure Baz()
    begin
    end;
}
"""


class ParseTests(unittest.TestCase):
    def setUp(self):
        self.r = cr.parse_report(REPORT)

    def test_model(self):
        r = self.r
        self.assertEqual(r.meta["version"], "2")
        self.assertTrue(r.complete())
        self.assertEqual(r.apps[APP1]["name"], "My App")
        self.assertFalse(r.objects[("PageExtension", 50201)]["measured"])
        self.assertEqual(r.lines[("Codeunit", 50100)][7], (1, True))
        self.assertEqual(r.skipped, 0)

    def test_quoted_signature_with_comma(self):
        sigs = [f[2] for f in self.r.functions[("Codeunit", 50100)]]
        self.assertIn("local procedure Bar(a: Integer, b: Text)", sigs)

    def test_doubled_quotes_in_signature(self):
        r = cr.parse_report('F,Codeunit,1,2,1,"procedure ""X Y""(a, b)"\n')
        self.assertEqual(r.functions[("Codeunit", 1)][0][2], 'procedure "X Y"(a, b)')
        self.assertEqual(cr.method_name(r.functions[("Codeunit", 1)][0][2]), "X Y")

    def test_malformed_and_duplicates(self):
        r = cr.parse_report("L,Codeunit,1,x,1,0\nL,Codeunit,1,5,1,0\nL,Codeunit,1,5,4,0\nO,bad\n")
        self.assertEqual(r.skipped, 2)
        self.assertEqual(r.lines[("Codeunit", 1)][5][0], 4)
        self.assertTrue(any("duplicate" in w for w in r.warnings))

    def test_incomplete_flag(self):
        r = cr.parse_report("M,complete,0\n")
        self.assertFalse(r.complete())
        self.assertIn("INCOMPLETE", cr.summary(r))


class LegacyCsvTests(unittest.TestCase):
    def test_bytes(self):
        out = cr.to_legacy_csv(cr.parse_report(REPORT))
        self.assertEqual(out, (
            "object_type,object_id,line_no,hits\r\n"
            "Codeunit,50100,5,3\r\nCodeunit,50100,6,0\r\nCodeunit,50100,7,1\r\n"
            "Codeunit,50102,3,2\r\n"
            "Codeunit,50200,4,5\r\n"
            "TableExtension,50110,4,0\r\n"))

    def test_legacy_input_to_cobertura_and_lcov(self):
        text = "object_type,object_id,line_no,hits\r\nCodeunit,50100,5,3\r\n5,50101,2,0\r\ngarbage\r\n"
        r = cr.parse_legacy_csv(text)
        self.assertEqual(r.skipped, 1)
        self.assertIn(("Codeunit", 50101), r.lines)  # ordinal 5 -> Codeunit
        root = ET.fromstring(cr.to_cobertura(r, timestamp_ms=1))
        self.assertEqual(root.get("lines-valid"), "2")
        self.assertEqual(root.get("lines-covered"), "1")
        pkg = root.find("packages/package")
        self.assertEqual(pkg.get("name"), cr.LEGACY_PACKAGE)
        self.assertEqual([c.get("name") for c in pkg.iter("class")],
                         ["Codeunit 50100", "Codeunit 50101"])
        lcov = cr.to_lcov(r)
        self.assertIn("SF:Codeunit 50100\nFNF:0\nFNH:0\nDA:5,3\nLF:1\nLH:1\nend_of_record", lcov)
        self.assertEqual(cr.to_legacy_csv(r).count("\r\n"), 3)


class SourceMappingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.makedirs(os.path.join(self.tmp.name, "src", "ext"))
        with open(os.path.join(self.tmp.name, "src", "Ops.al"), "w") as f:
            f.write(AL_OPS)
        with open(os.path.join(self.tmp.name, "src", "ext", "CustExt.al"), "w") as f:
            f.write(AL_EXT)
        self.m = cr.map_sources(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_paths_and_offsets(self):
        self.assertEqual(self.m[("Codeunit", 50100)], ("src/Ops.al", 0))
        # the first object closes on line 16, so BC numbers the next from line 17
        self.assertEqual(self.m[("Codeunit", 50102)], ("src/Ops.al", 16))
        self.assertEqual(self.m[("TableExtension", 50110)], ("src/ext/CustExt.al", 0))

    def test_comments_and_strings_ignored(self):
        self.assertNotIn(("Codeunit", 99999), self.m)
        self.assertNotIn(("Codeunit", 88888), self.m)
        self.assertNotIn(("Codeunit", 77777), self.m)
        self.assertEqual(len(self.m), 3)

    def test_keyword_case_and_quoting(self):
        objs = cr.find_objects('CodeUnit 5 "A B"\n{\n}\nPAGEEXTENSION 6 X extends Y\n{\n}\n')
        self.assertEqual([(t, i) for t, i, _s, _c in objs],
                         [("Codeunit", 5), ("PageExtension", 6)])
        self.assertEqual(objs[0][3], 3)

    def test_nested_keyword_is_not_a_declaration(self):
        objs = cr.find_objects('page 1 P\n{\n  action(A) { RunObject = page 2 Q; }\n}\n')
        self.assertEqual([(t, i) for t, i, _s, _c in objs], [("Page", 1)])

    def test_mapped_outputs(self):
        r = cr.parse_report(REPORT)
        root = ET.fromstring(cr.to_cobertura(r, self.m, self.tmp.name, 1))
        classes = {c.get("name"): c for c in root.iter("class")}
        second = classes["Codeunit 50102"]
        self.assertEqual(second.get("filename"), "src/Ops.al")
        # BC line 3 + offset 16
        self.assertEqual([ln.get("number") for ln in second.find("lines")], ["19"])
        # no mapping for 50200: named after the object
        self.assertEqual(classes["Codeunit 50200"].get("filename"), "Codeunit 50200")
        # relative: the viewer resolves filenames against the repository root
        self.assertEqual(root.find("sources/source").text, ".")
        lcov = cr.to_lcov(r, self.m)
        self.assertIn("SF:src/Ops.al\nFN:19,OnRun\nFNDA:1,OnRun\nFNF:1\nFNH:1\nDA:19,2\n", lcov)


class WriterTests(unittest.TestCase):
    def setUp(self):
        self.r = cr.parse_report(REPORT)

    def test_cobertura_structure(self):
        root = ET.fromstring(cr.to_cobertura(self.r, timestamp_ms=1234))
        self.assertEqual(root.tag, "coverage")
        self.assertEqual(root.get("timestamp"), "1234")
        self.assertEqual(root.get("lines-valid"), "6")
        self.assertEqual(root.get("lines-covered"), "4")
        self.assertEqual(root.get("line-rate"), f"{4 / 6:.4f}")
        self.assertEqual(root.get("branches-valid"), "0")
        self.assertEqual(root.find("sources/source").text, ".")
        pkgs = {p.get("name"): p for p in root.iter("package")}
        self.assertEqual(sorted(pkgs), ["My App", "Other App"])
        names = [c.get("name") for c in pkgs["Other App"].iter("class")]
        self.assertEqual(names, ["Codeunit 50200"])  # unmeasured PageExtension: no class
        cu = next(c for c in root.iter("class") if c.get("name") == "Codeunit 50100")
        self.assertEqual(cu.get("filename"), "Codeunit 50100")
        self.assertEqual(cu.get("line-rate"), f"{2 / 3:.4f}")
        lines = [(ln.get("number"), ln.get("hits"), ln.get("branch")) for ln in cu.find("lines")]
        # the partial line keeps branch="false": no branch counts are invented
        self.assertEqual(lines, [("5", "3", "false"), ("6", "0", "false"), ("7", "1", "false")])
        methods = {m.get("name"): m for m in cu.find("methods")}
        # Bar has no Code line: not coverable, so not a method
        self.assertEqual(sorted(methods), ["Foo"])
        self.assertEqual([ln.get("number") for ln in methods["Foo"].iter("line")], ["5", "6", "7"])
        self.assertEqual(methods["Foo"].get("line-rate"), f"{2 / 3:.4f}")

    def test_lcov(self):
        lcov = cr.to_lcov(self.r)
        self.assertIn(
            "TN:\nSF:Codeunit 50100\nFN:5,Foo\nFNDA:1,Foo\n"
            "FNF:1\nFNH:1\nDA:5,3\nDA:6,0\nDA:7,1\nLF:3\nLH:2\nend_of_record\n", lcov)
        self.assertEqual(lcov.count("end_of_record"), 4)
        self.assertNotIn("50201", lcov)

    def test_summary(self):
        s = cr.summary(self.r)
        self.assertIn("My App: 60.0% lines (3/5), 2/3 functions, 3 objects measured, 0 unmeasured", s)
        self.assertIn("Other App: 100.0% lines (1/1), 1/1 functions, 1 objects measured, 1 unmeasured", s)
        self.assertIn("Total: 66.7% lines (4/6), 3/4 functions, 4 objects measured, 1 unmeasured", s)
        self.assertIn("PageExtension 50201", s)
        self.assertIn("Complete: yes", s)
        self.assertNotIn("more", s.split("Unmeasured")[1])

    def test_summary_caps_unmeasured_list(self):
        for i in range(30):
            self.r.objects[("PageExtension", 60000 + i)] = {"measured": False, "app": APP2}
        s = cr.summary(self.r)
        line = [x for x in s.splitlines() if x.startswith("Unmeasured")][0]
        self.assertIn("31 unmeasured", s)
        self.assertEqual(line.count("PageExtension"), 20)
        self.assertTrue(line.endswith("... and 11 more"))


REDACTION = ("The extension that declares this object has its manifest property "
             "ShowMyCode set so that its source cannot be viewed.")

AL_TRIGGERS = """table 50300 "Dup Table"
{
    fields
    {
        field(1; A; Integer)
        {
            trigger OnValidate()
            begin
            end;
        }
        field(2; B; Integer)
        {
            trigger OnValidate()
            begin
            end;
        }
    }

    local procedure Helper(a: Integer; b: Text)
    begin
    end;
}
"""

AL_BRACES = """codeunit 50400 "Odd {Name"
{
    procedure Foo()
    begin
    end;
}

codeunit 50401 "Next } One"
{
}
"""


class LegacyV2Tests(unittest.TestCase):
    def test_legacy_mode_names_the_legacy_package(self):
        r = cr.parse_report("M,version,2\nM,mode,legacy\nO,Codeunit,50100,,1\n"
                            "L,Codeunit,50100,5,1,0\n")
        self.assertEqual(r.skipped, 0)
        root = ET.fromstring(cr.to_cobertura(r, timestamp_ms=1))
        self.assertEqual(root.find("packages/package").get("name"), cr.LEGACY_PACKAGE)
        self.assertIn("Mode: legacy", cr.summary(r))

    def test_ignored_and_diagnostics_in_summary(self):
        r = cr.parse_report("M,mode,apps\nM,ignored,aaa;bbb\nM,writes,3\nM,write_ms,1500\n"
                            "M,last_write_ms,400\nM,include_ms,90\nM,inventory_lines,1200\n")
        s = cr.summary(r)
        self.assertIn("WARNING: not measured: aaa, bbb", s)
        self.assertIn("writes 3", s)
        self.assertIn("last write ms 400", s)
        self.assertIn("inventory lines 1200", s)

    def test_control_characters_in_a_signature_keep_the_record_whole(self):
        text = ("F,Codeunit,1,3,1,procedure A()\x0b x\x1c y\r\nL,Codeunit,1,4,2,0\r\n"
                "L,Codeunit,1,5,0,0\r\n")
        r = cr.parse_report(text)
        self.assertEqual(r.skipped, 0)
        self.assertEqual(len(r.functions[("Codeunit", 1)]), 1)
        self.assertEqual(sorted(r.lines[("Codeunit", 1)]), [4, 5])


# Elements and attributes coverage-04.dtd allows (https://raw.githubusercontent.com/
# cobertura/web/master/htdocs/xml/coverage-04.dtd), as {element: (attributes, children)}.
DTD = {
    "coverage": ({"line-rate", "branch-rate", "lines-covered", "lines-valid",
                  "branches-covered", "branches-valid", "complexity", "version",
                  "timestamp"}, {"sources", "packages"}),
    "sources": (set(), {"source"}),
    "source": (set(), set()),
    "packages": (set(), {"package"}),
    "package": ({"name", "line-rate", "branch-rate", "complexity"}, {"classes"}),
    "classes": (set(), {"class"}),
    "class": ({"name", "filename", "line-rate", "branch-rate", "complexity"},
              {"methods", "lines"}),
    "methods": (set(), {"method"}),
    "method": ({"name", "signature", "line-rate", "branch-rate"}, {"lines"}),
    "lines": (set(), {"line"}),
    "line": ({"number", "hits", "branch", "condition-coverage"}, {"conditions"}),
}
DTD_REQUIRED = {
    "coverage": DTD["coverage"][0] - set(),
    "package": DTD["package"][0],
    "class": DTD["class"][0],
    "method": DTD["method"][0],
    "line": {"number", "hits"},
}


class StandardsTests(unittest.TestCase):
    """What other tools reject: pinned from coverage-04.dtd and lcov 2.x."""

    def check_dtd(self, root):
        for el in root.iter():
            self.assertIn(el.tag, DTD, f"element <{el.tag}> not in the DTD")
            attrs, children = DTD[el.tag]
            extra = set(el.attrib) - attrs
            self.assertFalse(extra, f"<{el.tag}> has attributes the DTD does not allow: {extra}")
            missing = DTD_REQUIRED.get(el.tag, set()) - set(el.attrib)
            self.assertFalse(missing, f"<{el.tag}> lacks required attributes: {missing}")
            for child in el:
                self.assertIn(child.tag, children, f"<{child.tag}> not allowed in <{el.tag}>")

    def test_cobertura_conforms_to_the_dtd(self):
        r = cr.parse_report(REPORT)
        self.check_dtd(ET.fromstring(cr.to_cobertura(r, timestamp_ms=1)))

    def test_method_has_no_complexity(self):
        root = ET.fromstring(cr.to_cobertura(cr.parse_report(REPORT), timestamp_ms=1))
        self.assertTrue(all("complexity" not in m.attrib for m in root.iter("method")))
        self.assertTrue(all("complexity" in c.attrib for c in root.iter("class")))

    def test_lcov_fn_is_on_a_line_with_da(self):
        r = cr.parse_report(
            "F,Codeunit,1,3,1,procedure A()\nL,Codeunit,1,5,1,0\nL,Codeunit,1,6,0,0\n"
            "F,Codeunit,1,9,0,procedure Empty()\n"
            "F,Codeunit,1,12,0,procedure B()\nL,Codeunit,1,14,0,0\n")
        lcov = cr.to_lcov(r)
        fn = {x.split(":")[1].split(",")[0] for x in lcov.split("\n") if x.startswith("FN:")}
        da = {x.split(":")[1].split(",")[0] for x in lcov.split("\n") if x.startswith("DA:")}
        self.assertEqual(fn, {"5", "14"})
        self.assertTrue(fn <= da)
        self.assertNotIn("Empty", lcov)
        self.assertIn("FNF:2\nFNH:1\n", lcov)

    def test_empty_functions_are_not_counted_anywhere(self):
        text = ("L,Codeunit,1,5,1,0\nF,Codeunit,1,3,1,procedure A()\n"
                "F,Codeunit,1,8,0,procedure Empty()\nF,Codeunit,1,10,0,trigger OnRun()\n")
        r = cr.parse_report(text)
        self.assertIn("1/1 functions", cr.summary(r))
        cob = cr.to_cobertura(r, timestamp_ms=1)
        self.assertNotIn("Empty", cob)
        self.assertEqual(cob.count("<method "), 1)

    def test_session_mode_is_in_the_summary(self):
        r = cr.parse_report("M,sessions,test\nL,Codeunit,1,5,1,0\n")
        self.assertIn("Sessions recorded: test", cr.summary(r))


class MethodNameTests(unittest.TestCase):
    def test_redaction_text_is_not_a_declaration(self):
        self.assertFalse(cr.is_declaration(REDACTION))
        self.assertIsNone(cr.method_name(REDACTION))
        self.assertTrue(cr.is_declaration("  LOCAL Procedure Foo()"))
        self.assertTrue(cr.is_declaration("trigger OnRun()"))
        self.assertTrue(cr.is_declaration(""  + "internal procedure X()"))

    def test_redacted_without_source_falls_back_to_the_line(self):
        r = cr.parse_report(f'F,Codeunit,1,7,1,"{REDACTION}"\nF,Codeunit,1,9,0,\nL,Codeunit,1,8,1,0\n')
        names = [m[1] for m in cr._methods(r, ("Codeunit", 1))]
        self.assertEqual(names, ["L7"])  # L9 has no Code line: not coverable
        lcov = cr.to_lcov(r)
        self.assertIn("FN:8,L7", lcov)
        self.assertNotIn("ShowMyCode", lcov)

    def test_redacted_name_comes_from_the_source(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "Ops.al"), "w") as f:
                f.write(AL_OPS)
            m = cr.map_sources(d)
            r = cr.parse_report(f'F,Codeunit,50100,12,1,"{REDACTION}"\n'
                                f'F,Codeunit,50102,4,0,\nL,Codeunit,50100,14,1,0\nL,Codeunit,50102,5,1,0\n')
            ms = cr._methods(r, ("Codeunit", 50100), m)
            self.assertEqual(ms[0][1], "Foo")
            self.assertEqual(ms[0][4], "procedure Foo()")
            ms2 = cr._methods(r, ("Codeunit", 50102), m)
            self.assertEqual(ms2[0][1], "OnRun")

    def test_duplicate_trigger_names_are_made_unique(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "T.al"), "w") as f:
                f.write(AL_TRIGGERS)
            m = cr.map_sources(d)
            r = cr.parse_report(
                "F,Table,50300,7,1,trigger OnValidate()\nF,Table,50300,13,0,trigger OnValidate()\n"
                'F,Table,50300,19,1,"local procedure Helper(a: Integer, b: Text)"\n'
                "L,Table,50300,8,1,0\nL,Table,50300,14,0,0\nL,Table,50300,20,1,0\n")
            names = [x[1] for x in cr._methods(r, ("Table", 50300), m)]
            self.assertEqual(names, ["OnValidate", "OnValidate@13", "Helper"])
            lcov = cr.to_lcov(r, m)
            fn = [ln for ln in lcov.split("\n") if ln.startswith("FN:")]
            self.assertEqual(len(fn), 3)
            for ln in fn:
                self.assertEqual(ln.count(","), 1)
            root = ET.fromstring(cr.to_cobertura(r, m, d, 1))
            self.assertEqual([x.get("name") for x in root.iter("method")], names)

    def test_comma_in_a_name_is_safe_in_lcov(self):
        r = cr.parse_report('F,Codeunit,1,3,1,"procedure ""A,B""()"\nL,Codeunit,1,4,1,0\n')
        fn = [ln for ln in cr.to_lcov(r).split("\n") if ln.startswith(("FN:", "FNDA:"))]
        self.assertTrue(all(ln.count(",") == 1 for ln in fn), fn)


class RootAndSourceTests(unittest.TestCase):
    def test_paths_are_relative_to_root(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "app", "src"))
            with open(os.path.join(d, "app", "src", "X.al"), "w") as f:
                f.write(AL_EXT)
            m = cr.map_sources(os.path.join(d, "app"), d)
            self.assertEqual(m[("TableExtension", 50110)], ("app/src/X.al", 0))
            self.assertEqual(cr.map_sources(os.path.join(d, "app"))[("TableExtension", 50110)],
                             ("src/X.al", 0))
            rep = os.path.join(d, "r.txt")
            with open(rep, "w") as f:
                f.write("L,TableExtension,50110,4,1,0\n")
            xml = os.path.join(d, "o.xml")
            p = subprocess.run([sys.executable, os.path.join(HERE, "coverage_report.py"),
                                "--report", rep, "--source", os.path.join(d, "app"),
                                "--root", d, "--cobertura", xml], capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            root = ET.parse(xml).getroot()
            self.assertEqual(root.find("sources/source").text, ".")
            self.assertEqual(root.find(".//class").get("filename"), "app/src/X.al")

    def test_braces_in_quoted_identifiers(self):
        objs = cr.find_objects(AL_BRACES)
        self.assertEqual([(t, i, s, c) for t, i, s, c in objs],
                         [("Codeunit", 50400, 1, 6), ("Codeunit", 50401, 8, 10)])

    def test_package_and_output_dirs_are_skipped(self):
        with tempfile.TemporaryDirectory() as d:
            for sub in (".alpackages", ".snapshots", "node_modules", ".git", ".vscode", "src"):
                os.makedirs(os.path.join(d, sub))
                with open(os.path.join(d, sub, "A.al"), "w") as f:
                    f.write("codeunit 5 X\n{\n}\n" if sub != "src" else "codeunit 6 Y\n{\n}\n")
            self.assertEqual(sorted(cr.map_sources(d)), [("Codeunit", 6)])

    def test_many_functions_and_lines_stay_fast(self):
        rows = [f"F,Codeunit,1,{i * 10},1,procedure P{i}()" for i in range(5000)]
        rows += [f"L,Codeunit,1,{i * 10 + 1},1,0" for i in range(5000)]
        r = cr.parse_report("\n".join(rows))
        ms = cr._methods(r, ("Codeunit", 1))
        self.assertEqual(len(ms), 5000)
        self.assertEqual(ms[4999][3], [(49991, 1)])


class CliTests(unittest.TestCase):
    def test_cli_writes_everything(self):
        with tempfile.TemporaryDirectory() as d:
            rep = os.path.join(d, "report.txt")
            with open(rep, "w") as f:
                f.write(REPORT)
            outs = {k: os.path.join(d, k) for k in ("csv", "xml", "lcov")}
            p = subprocess.run(
                [sys.executable, os.path.join(HERE, "coverage_report.py"), "--report", rep,
                 "--complete", "false", "--csv-out", outs["csv"], "--cobertura", outs["xml"],
                 "--lcov", outs["lcov"]], capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertIn("INCOMPLETE", p.stdout)
            with open(outs["csv"], newline="") as f:
                self.assertTrue(f.read().startswith("object_type,object_id,line_no,hits\r\n"))
            ET.parse(outs["xml"])
            self.assertTrue(os.path.getsize(outs["lcov"]) > 0)


if __name__ == "__main__":
    unittest.main(verbosity=1)
