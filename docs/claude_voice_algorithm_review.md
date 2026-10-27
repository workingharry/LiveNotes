func testChineseNoSpaceMultiCommit() {
    var committed = NormalizedText("你好嗎").chars
    let r1 = TranscriptAligner.extractDelta(full: "你好嗎我很好", committed: committed)
    XCTAssertEqual(r1.text, "我很好"); committed = r1.normalized
    let r2 = TranscriptAligner.extractDelta(full: "你好嗎我很好今天", committed: committed)
    XCTAssertEqual(r2.text, "今天")                      // 舊實作會得到「天」
}
func testTailRevisionDoesNotDuplicate() {
    let c = NormalizedText("It's a test").chars
    XCTAssertEqual(TranscriptAligner.extractDelta(full: "Its a test again", committed: c).text, "again")
}
func testBackoffBounds() {
    var p = RetryPolicy()
    for i in 0..<10 {
        let d = p.nextDelay(random: { $0.upperBound })   // 注入隨機源
        XCTAssertLessThanOrEqual(d, 30); if i == 0 { XCTAssertEqual(d, 0.5) }
    }
}