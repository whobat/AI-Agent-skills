# peppol-validation — Reference

Document-type map, gotchas, and verification for `scripts/Invoke-PeppolValidation.ps1`.
For the agent-facing workflow see [SKILL.md](SKILL.md).

## How identification works

The script reads two things from each document and never trusts the filename:

- the **root element** local name (`Invoice`, `CreditNote`, `Order`, `DespatchAdvice`,
  `ApplicationResponse`, `Catalogue`, …), and
- `cbc:CustomizationID` (namespace-agnostic, via `local-name()`).

It maps that pair to a Peppol BIS 3.0 **VESID** (the validation rule set the public service
runs). Billing invoice and credit note share one CustomizationID (`…poacc:billing:3.0`) and
are told apart by the root element; self-billing uses `…poacc:selfbilling:3.0`; all other
post-award documents are matched by their `poacc:trns:<doc>:3` token (most specific first, so
`order_response` wins over `order`).

If nothing matches, the document is reported **non-standard** (not Peppol BIS 3.0) and is not
auto-validated — this is the signal for "old schema / wrong format", e.g. a CENBII
`biitrns…peppol28a:ver1.0` order, OIOUBL, or a UN/CEFACT CII invoice.

## Document type → VESID map

These VESIDs live at the top of the script (`$VesByArtifact`). **They version quarterly** —
when OpenPeppol ships a new release, bump them. Authoritative list:
<https://peppol.helger.com/public/menuitem-validation-ws2>.

| Document (root) | CustomizationID token | VESID (current) |
|-----------------|-----------------------|-----------------|
| Invoice | `…poacc:billing:3.0` | `eu.peppol.bis3:invoice:2025.11` |
| Credit Note (`CreditNote`) | `…poacc:billing:3.0` | `eu.peppol.bis3:creditnote:2025.11` |
| Invoice self-billing | `…poacc:selfbilling:3.0` | `eu.peppol.bis3:invoice-self-billing:2026.3` |
| Credit Note self-billing | `…poacc:selfbilling:3.0` | `eu.peppol.bis3:creditnote-self-billing:2026.3` |
| Order | `poacc:trns:order:3` | `eu.peppol.bis3:order:2025.11` |
| Order Response | `poacc:trns:order_response:3` | `eu.peppol.bis3:order-response:2025.11` |
| Order Response (Advanced) | `poacc:trns:order_response_advanced:3` | `eu.peppol.bis3:order-response-advanced:2025.11` |
| Order Change | `poacc:trns:order_change:3` | `eu.peppol.bis3:order-change:2025.11` |
| Order Cancellation | `poacc:trns:order_cancellation:3` | `eu.peppol.bis3:order-cancellation:2025.11` |
| Order Agreement | `poacc:trns:order_agreement:3` | `eu.peppol.bis3:order-agreement:2025.11` |
| Catalogue | `poacc:trns:catalogue:3` | `eu.peppol.bis3:catalogue:2025.11` |
| Catalogue Response | `poacc:trns:catalogue_response:3` | `eu.peppol.bis3:catalogue-response:2025.11` |
| Despatch Advice | `poacc:trns:despatch_advice:3` | `eu.peppol.bis3:despatch-advice:2025.11` |
| Message Level Response (MLR) | `poacc:trns:mlr:3` | `eu.peppol.bis3:mlr:2025.11` |
| Punch Out | `poacc:trns:punch_out:3` | `eu.peppol.bis3:punch-out:2025.11` |
| Invoice Message Response | `poacc:trns:invoice_message_response:3` | `eu.peppol.bis3:invoice-message-response:2025.11` |

`2025.11` = OpenPeppol BIS 3.0.16. Self-billing tracks its own version line.

## The validation web service (SOAP)

- Endpoint default `https://peppol.helger.com/wsdvs`; namespace
  `http://peppol.helger.com/ws/documentvalidationservice/201701/`; SOAPAction `validate`.
- Request `validateRequestInput` carries the document in `<ws:XML>` (CDATA) plus a **`VESID`
  attribute** and `displayLocale`.
- Response `validateResponseOutput @success/@mostSevereErrorLevel`, with one `Result` per
  artefact (`xsd`, `schematron-xslt`) and an `Item` per finding (`@errorLevel` =
  SUCCESS|WARN|ERROR, `@errorID`, `@errorFieldName`, `@errorText`).
- Same API on a self-hosted **phive-ws** (Docker) — point `-Endpoint` at it.

## Using a local validator (config.json)

Copy `config.example.json` → `config.json` in the skill folder to switch off the public
service. Keys (all optional):

- `endpoint` — your self-hosted phive-ws URL (e.g. `http://localhost:8080/wsdvs`). Used unless
  `-Endpoint` is passed explicitly. **Omit it (or leave it as `_endpoint`) and the default
  public OpenPeppol/Helger service is used** — localhost is never the default, only an explicit
  opt-in.
- `vesByArtifact` — per-document-type VESID overrides, merged over the built-in defaults
  (keys starting with `_` are ignored, so you can leave notes). Lets you bump a quarterly
  release without editing the script.

The script auto-discovers `config.json` next to the skill (one level up from `scripts/`), or
wherever `-ConfigPath` points. `config.json` is gitignored and preserved on skill update;
`config.example.json` is the committed template. A self-hosted phive-ws keeps documents
(customer names, CVR, prices) on your own network and removes the public-service rate limit.

## Gotchas

These are the traps that produce confident-but-wrong results. **At the start of a run, read
`gotchas.local.md` in this skill's folder if it exists** (environment-specific traps — real
endpoints, partner quirks); it is gitignored and preserved across updates. **When you learn a
new environment-specific pitfall, append it there**, not to this committed file (which must
stay generic — no company/partner data).

- **`VESID="auto"` is NOT supported by the web service.** It returns *"Syntactically invalid
  VESID"*. Helger's "determine automatically" is a UI-only feature. → This skill does the
  detection client-side (root + CustomizationID → VESID). Don't try to pass `auto`.
- **The public instance rate-limits (HTTP 429).** Under batch load you get 429s and, if you
  ignore them, files silently go un-validated. → The script retries with backoff and paces
  requests; for real batches/production self-host phive-ws (`-Endpoint`). Never report a file
  as passed if its run hit 429 and didn't recover.
- **Peppol rulesets version quarterly.** A hardcoded VESID goes stale; an outdated ruleset can
  pass a document a newer one would reject (or vice versa). → Keep `$VesByArtifact` current
  (table above) and note in your answer which release ran (the `Result/@artifactPath` shows it,
  e.g. `…/openpeppol/2025.11/…`).
- **"Valid XML" ≠ "valid Peppol".** A file can be well-formed and even XSD-valid but fail
  Schematron (the business rules) — and vice versa, a non-standard schema is "valid XML" but
  not your standard at all. → Trust only a run where BOTH the `xsd` and `schematron-xslt`
  artefacts ran and reported success. Exit 3 (non-standard) is not "valid".
- **CustomizationID, not the root element, decides the standard.** Two `Order` files can be a
  current BIS 3.0 order and an old CENBII `peppol28a` order. → Always look at the
  CustomizationID the script prints; same root element says nothing about the standard.
- **Data egress.** The default endpoint is a public third-party service that receives the full
  document (customer names, CVR, addresses, prices). → For PII/production use a self-hosted
  endpoint; only send to the public service when the content is non-sensitive or test data.
- **Restricted party models bite.** Some transactions forbid UBL elements that look valid
  (e.g. Despatch Advice T16 rejects `cac:PartyName` and `PartyLegalEntity/cbc:CompanyID` on
  the supplier/customer parties — rules B02003/B03602/B04303/B05902). → Read the rule ID in the
  error, not just the message; the fix is usually "remove an element that isn't in this
  transaction's data model", not "add data".

## Verification

**Before trusting any result (preconditions/ground truth):**
1. Confirm the script parses and the endpoint is reachable by validating a **known-good file**
   first (e.g. a previously-passing invoice) — a clean `[OK]` proves the toolchain and network
   path before you judge the file in question.
2. Confirm the run actually identified a BIS 3.0 ruleset (the `Standard: [OK]` line and a
   `Ruleset:` VESID). If it says non-standard, the document was **not** Schematron-checked —
   say so rather than implying it passed.

**After (output check):**
1. A document is "valid" only when the script prints `Result: [OK] valid - no errors` AND the
   run was not interrupted/rate-limited. Cross-check the batch summary counts and the exit code
   (`0` all valid; `1` errors; `3` non-standard; `2` technical).
2. For reproducibility, keep the raw response with `-ReportFolder` and verify both artefacts
   (`xsd`, `schematron-xslt`) show `success="true"`.
3. **Fail loud** if any file ended in exit 2 (technical) — that file's validity is unknown, not
   confirmed.

## Related

This validates documents. A companion AX 2012 → Peppol Despatch Advice **converter** produces
documents that this skill then validates; keep the two concerns separate (generate vs. verify).
