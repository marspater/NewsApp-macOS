import Foundation

@main
struct TensionCalibrationRunner {
    static func main() async {
        do {
            try await TensionCalibrationTests.runAllTests()
            print("✅ All tension calibration tests passed successfully!")
        } catch {
            print("❌ Tension calibration tests failed: \(error)")
            exit(1)
        }
    }
}
