import Foundation

// Default gateway address. The public repository keeps it empty: CI writes the
// real value from the TGESHKA_GATEWAY_URL secret before building, and users can
// always set the address in Settings or with a tgeshka://gateway link.
enum TGeshkaBuildDefaults {
    static let gatewayUrl = ""
}
