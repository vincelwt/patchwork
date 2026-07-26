import XCTest
@testable import PiDeskCLI
import PiDeskKit

/// The CLI validates `--cron` and the daemon evaluates it. If the two grammars disagree, a
/// schedule the CLI accepts can silently never fire, which is the exact failure the contract
/// warns about — so they are checked against each other here.
final class CronGrammarAgreementTests: XCTestCase {
    private let corpus = [
        "0 9 * * 1-5", "*/15 * * * *", "0 0 * * 7", "0 0 * * 0", "0,15,30,45 * * * *",
        "0 9 1 JAN-MAR MON,WED,FRI", "5 4 * * sun", "0 22 * * 1-5", "23 0-20/2 * * *",
        "0 0 1 * *", "0 9 * *", "0 9 * * * *", "60 * * * *", "* * * * 8", "@daily",
        "", "0 9 32 * *", "0 9 * 13 *", "*/0 * * * *", "1-0 * * * *",
        "*/7 0-23 * * *", "0 0 29 2 *", "15 14 1 * *", "0 22 * * MON-FRI", "*/5 * * * MON",
        "0 0 * * 1,3,5", "a * * * *", "* * * * mon-", "0 9 * * 1-", "**/2 * * * *",
        "0 9 * * FRI,SAT", "0 0 0 * *", "-1 * * * *", "0 9 * * 1-5,7", " 0  9 * * 1-5 "
    ]

    func testTheCLIAndTheDaemonAcceptExactlyTheSameExpressions() {
        for expression in corpus {
            let cliAccepts = (try? PiDeskCLI.CronExpression.validate(expression)) != nil
            let daemonAccepts = (try? PiDeskKit.CronExpression(parsing: expression)) != nil
            XCTAssertEqual(cliAccepts, daemonAccepts, "disagreement on \"\(expression)\": cli=\(cliAccepts) daemon=\(daemonAccepts)")
        }
    }
}
