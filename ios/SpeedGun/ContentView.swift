import SwiftUI

struct ContentView: View {
    @StateObject private var engine = DopplerEngine()
    @State private var unit: SpeedUnit = .mph
    @State private var carrierText: String = "18000"

    enum SpeedUnit: String, CaseIterable, Identifiable {
        case mph, kmh, mps
        var id: String { rawValue }
        var label: String {
            switch self {
            case .mph: return "mph"
            case .kmh: return "km/h"
            case .mps: return "m/s"
            }
        }
        func convert(fromMph mph: Double) -> Double {
            switch self {
            case .mph: return mph
            case .kmh: return mph * 1.60934
            case .mps: return mph / 2.23694
            }
        }
    }

    private var displaySpeed: String {
        guard engine.speedMph > 0.1 else { return "—" }
        return String(format: "%.1f", unit.convert(fromMph: engine.speedMph))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 10) {
                Text("DOPPLER SPEED GUN")
                    .font(.caption.weight(.bold))
                    .tracking(2)
                    .foregroundColor(.blue)
                    .padding(.top, 8)

                Spacer(minLength: 0)

                Text(displaySpeed)
                    .font(.system(size: 128, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white)
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
                    .padding(.horizontal)

                Text(engine.direction.isEmpty ? unit.label : "\(unit.label) \(engine.direction)")
                    .font(.title3)
                    .foregroundColor(.gray)

                Spacer(minLength: 0)

                Button(action: {
                    if engine.running { engine.stop() } else { engine.start() }
                }) {
                    Text(engine.running ? "Stop" : "Start")
                        .font(.title2.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(engine.running ? Color.red : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(14)
                }
                .padding(.horizontal)

                Text(engine.statusMessage)
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 36)
                    .padding(.horizontal)

                DisclosureGroup("Settings") {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Mode", selection: $engine.mode) {
                            ForEach(DopplerEngine.Mode.allCases) { m in
                                Text(m.label).tag(m)
                            }
                        }
                        .disabled(engine.running)

                        HStack {
                            Text("Carrier (Hz)")
                                .foregroundColor(.white)
                            Spacer()
                            TextField("18000", text: $carrierText)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                                .disabled(engine.running)
                                .onSubmit {
                                    if let v = Double(carrierText), v >= 12000, v <= 22000 {
                                        engine.carrierHz = v
                                    } else {
                                        carrierText = String(Int(engine.carrierHz))
                                    }
                                }
                        }

                        Picker("Units", selection: $unit) {
                            ForEach(SpeedUnit.allCases) { u in
                                Text(u.label).tag(u)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .tint(.blue)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(white: 0.08))
                .cornerRadius(12)
                .padding(.horizontal)

                Text("Works best on people, cars, and thrown balls at close range. Small fast objects (hockey pucks) are inconsistent.")
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.bottom, 12)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { carrierText = String(Int(engine.carrierHz)) }
    }
}

#Preview {
    ContentView()
}
