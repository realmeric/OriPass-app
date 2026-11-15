import Carbon.HIToolbox

/// Secure event input: while it is on, no other process on the Mac is handed
/// the keys being typed, which is what a password field owes whoever types
/// into it. It also stops every text expander and every hot key that reads
/// keys, on the whole Mac, so it is on for as long as the field has the keys
/// and not a moment longer.
///
/// The system counts each process's ons against its offs. This holds at most
/// one, so it can be told "off" twice and "on" twice without the count
/// drifting.
final class SecureInput {
    private(set) var isOn = false

    func set(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        if on { EnableSecureEventInput() } else { DisableSecureEventInput() }
    }

    deinit {
        if isOn { DisableSecureEventInput() }
    }
}
