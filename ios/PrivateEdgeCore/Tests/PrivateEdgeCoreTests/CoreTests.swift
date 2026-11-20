import XCTest
@testable import PrivateEdgeCore

final class CoreTests: XCTestCase {
    let ref = ReferenceTime(iso: "2026-11-02T10:00:00-05:00")!

    func testPromptMatchesPythonRenderer() {
        // Same literal as harness/tests/test_harness.py::test_render_llama32_pins_the_reference_date
        XCTAssertEqual(ChatPrompt.renderLlama32(system: " SYS ", user: "USER\n", ref: ref),
                       "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n"
                       + "Cutting Knowledge Date: December 2023\nToday Date: 02 Nov 2026\n\n"
                       + "SYS<|eot_id|><|start_header_id|>user<|end_header_id|>\n\nUSER<|eot_id|>"
                       + "<|start_header_id|>assistant<|end_header_id|>\n\n")
    }

    func testReferenceTimeKeepsItsOffset() {
        XCTAssertEqual(ref.format("EEEE, d MMMM yyyy, HH:mm"), "Monday, 2 November 2026, 10:00")
        XCTAssertEqual(ReferenceTime(iso: "2027-03-15T09:00:00-04:00")!.format("HH:mm"), "09:00")
    }

    func testQueryTermsMatchPython() {
        XCTAssertEqual(Query.terms("When is my doctor's appointment?"), ["doctor", "appointment"])
    }

    func testBM25RanksAndSurvivesOperators() throws {
        let idx = try BM25Index(notes: [Note(id: "n-1", title: "Dr. Patel", body: "Dr. Patel, Tue 3pm."),
                                        Note(id: "n-2", title: "Wifi", body: "Home wifi password tangerine-4471.")])
        XCTAssertEqual(idx.search("what's the wifi password?", k: 3).first?.noteID, "n-2")
        XCTAssertEqual(idx.search("wifi AND \"password\" OR NEAR(*)", k: 3).first?.noteID, "n-2")
        XCTAssertTrue(idx.search("what is it?", k: 3).isEmpty)
    }

    func testParseOutputAndAbstain() {
        let (a, c, ok) = NotesTask.parseOutput("```json\n{\"answer\": \"0629\", \"citations\": [{\"note_id\": \"n-010\", \"quote\": \"Bike lock combo 0629.\"}]}\n```")
        XCTAssertEqual(a, "0629"); XCTAssertEqual(c.first?.note_id, "n-010"); XCTAssertTrue(ok)
        let (raw, _, bad) = NotesTask.parseOutput("{\"answer\": the notes don't say}")
        XCTAssertFalse(bad); XCTAssertEqual(raw, "{\"answer\": the notes don't say}")
        XCTAssertTrue(NotesTask.isAbstain("The notes don't say."))
        XCTAssertFalse(NotesTask.isAbstain("the notes don't say the seat"))
    }
}
