---
status: accepted
---

# Direct client-to-SimpleFIN architecture

Cashew connects directly from the client device to the SimpleFIN Bridge over HTTPS, storing Access URLs in Flutter Secure Storage rather than routing through an intermediate backend proxy. This preserves Cashew's local-first privacy model and avoids server infrastructure, at the trade-off of disabling SimpleFIN sync on Flutter Web due to browser CORS restrictions.
