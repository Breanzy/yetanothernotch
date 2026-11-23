import EventKit
import SwiftUI

struct CalendarView: View {
    @EnvironmentObject var cal: CalendarService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WeekStrip(selected: $cal.selectedDate)
            switch cal.access {
            case .granted:
                if cal.events.isEmpty {
                    VStack(spacing: 4) {
                        Image(systemName: "calendar.badge.checkmark")
                            .font(.system(size: 18))
                        Text("No events")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(cal.events, id: \.calendarItemIdentifier) { EventRow(event: $0) }
                        }
                    }
                }
            case .unknown, .denied:
                VStack(spacing: 6) {
                    Text(cal.access == .denied ? "Calendar access is off" : "See your events here")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                    PillButton(title: cal.access == .denied ? "Open Settings" : "Connect Calendar") {
                        cal.requestAccess()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct WeekStrip: View {
    @EnvironmentObject var service: CalendarService
    @Binding var selected: Date
    private let cal = Calendar.current

    private var days: [Date] {
        service.weekStripDays(around: cal.startOfDay(for: Date()))
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(days, id: \.self) { day in
                let isSelected = cal.isDate(day, inSameDayAs: selected)
                let isToday = cal.isDateInToday(day)
                Button {
                    selected = day
                } label: {
                    VStack(spacing: 2) {
                        Text(day.formatted(.dateTime.weekday(.narrow)))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                        Text(day.formatted(.dateTime.day()))
                            .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(isSelected ? Color.white : .clear))
                            .foregroundStyle(isSelected ? .black : (isToday ? .accentColor : .white))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct EventRow: View {
    let event: EKEvent

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: event.calendar?.color ?? .systemBlue))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "Untitled")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(timeText)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 0)
        }
        .frame(height: 28)
        .opacity(event.endDate < Date() ? 0.45 : 1)
    }

    private var timeText: String {
        if event.isAllDay { return "All day" }
        let f = Date.FormatStyle(date: .omitted, time: .shortened)
        return "\(event.startDate.formatted(f)) – \(event.endDate.formatted(f))"
    }
}

struct BatteryView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            if let info = BatteryInfo.read() {
                HStack(spacing: 4) {
                    Text("\(info.level)%")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                    Image(systemName: info.symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(info.isCharging ? .green : (info.level <= 20 ? .red : .white))
                }
                .foregroundStyle(.white.opacity(0.8))
            }
        }
    }
}
