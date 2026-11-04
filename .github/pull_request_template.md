## What and why

<!-- What does this change, and why? Link the issue it closes. -->

## Checklist

- [ ] Tests cover the behaviour change
- [ ] Server: `mix format --check-formatted`, `mix test`, `mix sobelow --exit medium` pass
- [ ] Mobile: `flutter analyze` and `flutter test` pass
- [ ] User-visible changes are under **Unreleased** in `CHANGELOG.md`
- [ ] No secrets, real OTP emails, record IDs or keystores are included
- [ ] If this touches keys, the record credential, logging or sender verification, the security impact is described above
