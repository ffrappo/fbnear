import Foundation
import MapKit

/// Driving ETAs (MapKit) and date-window logic in Europe/Rome.
enum Geo {
    static let rome = TimeZone(identifier: "Europe/Rome")!

    static func eta(origin: (Double, Double), dest: (Double, Double)) async throws -> (seconds: Double, meters: Double)? {
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: origin.0, longitude: origin.1)))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: dest.0, longitude: dest.1)))
        req.transportType = .automobile
        req.departureDate = Date()
        let resp = try await MKDirections(request: req).calculate()
        guard let r = resp.routes.first else { return nil }
        return (r.expectedTravelTime, r.distance)
    }

    static func etaBatch(origin: (Double, Double), dests: [(Double, Double)], concurrency: Int = 4) async -> [Int: (seconds: Double, meters: Double)?] {
        var results: [Int: (Double, Double)?] = [:]
        await withTaskGroup(of: (Int, (Double, Double)?).self) { group in
            var iter = dests.enumerated().makeIterator()
            var inFlight = 0
            func addNext(_ g: inout TaskGroup<(Int, (Double, Double)?)>) {
                guard let (i, d) = iter.next() else { return }
                g.addTask {
                    let r = try? await eta(origin: origin, dest: d)
                    return (i, r.map { ($0.seconds, $0.meters) })
                }
                inFlight += 1
            }
            for _ in 0..<concurrency { addNext(&group) }
            while let next = await group.next() {
                inFlight -= 1
                results[next.0] = next.1
                addNext(&group)
            }
        }
        return results
    }

    /// Geocodes a free-text venue via MKLocalSearch when the event has no coordinates.
    static func geocode(_ query: String, near: (Double, Double)) async -> (Double, Double)? {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: near.0, longitude: near.1),
            latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        guard let resp = try? await MKLocalSearch(request: req).start(),
              let item = resp.mapItems.first,
              let c = item.placemark.location?.coordinate else { return nil }
        return (c.latitude, c.longitude)
    }

    // MARK: date windows

    static func dayStart(_ date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date)
    }

    static func localDate(_ epoch: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(epoch))
    }

    /// Event overlaps the local calendar day of `day` (00:00-24:00 Europe/Rome).
    static func happens(onDay day: Date, start: Date, end: Date, calendar: Calendar) -> Bool {
        let dayBegin = dayStart(day, calendar: calendar)
        let dayEnd = dayBegin.addingTimeInterval(86_400)
        return start < dayEnd && end > dayBegin
    }
}
