/// Registrar response acceptance for trouter registrations.
///
/// The registrar returns HTTP 202 with an empty body on success. Accept any
/// 2xx; only non-2xx is a failure (body then carries the diagnosis).
///
/// Refs: purple-teams teams_trouter.c `teams_trouter_register_one` fires the
/// registrar POST with a NULL response callback — status/body never checked,
/// so 202-empty succeeds there by construction. ost
/// src/trouter/registrar.rs checks `status.is_success()` and only reads the
/// body on failure.
public enum RegistrarResponse {
    public static func isSuccess(statusCode: Int) -> Bool {
        (200...299).contains(statusCode)
    }
}
