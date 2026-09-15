import Testing

@testable import CompassCore

func thrownIssues(_ body: () throws -> Any) -> ConfigIssues? {
    do {
        _ = try body()
        return nil
    } catch let issues as ConfigIssues {
        return issues
    } catch {
        return nil
    }
}
