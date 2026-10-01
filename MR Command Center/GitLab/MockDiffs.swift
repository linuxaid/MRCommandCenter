import Foundation

/// Sample diffs for the mock MRs. Between them they cover every case the Changes view
/// handles: modified, new, deleted, renamed (with and without edits), binary, generated,
/// collapsed, too large, a diff over the collapse threshold, and an overflowing MR.
/// They also seed the phase 4 static checks (debug output, TODOs, a fake AWS key,
/// source changes without tests).
nonisolated enum MockDiffs {
    static func diffs(forIID iid: Int) -> [GitLabDiff] {
        switch iid {
        case 412: webhookRetries
        case 1873: savedCarts
        case 77: terraformBump
        case 415: ledgerRefactor
        case 1880: currencyRounding
        case 80: vaultRotation
        case 1884: lazyImages
        case 420: refundIdempotency
        default: []
        }
    }

    /// GitLab's `changes_count`. MR 1884 overflows GitLab's limits.
    static func changesCount(forIID iid: Int) -> String {
        iid == 1884 ? "1000+" : String(diffs(forIID: iid).count)
    }

    private static func modified(_ path: String, _ diff: String, generated: Bool = false) -> GitLabDiff {
        GitLabDiff(oldPath: path, newPath: path, aMode: "100644", bMode: "100644", diff: diff,
                   newFile: false, renamedFile: false, deletedFile: false, generatedFile: generated)
    }

    private static func added(_ path: String, _ lines: [String]) -> GitLabDiff {
        let body = "@@ -0,0 +1,\(lines.count) @@\n" + lines.map { "+" + $0 }.joined(separator: "\n") + "\n"
        return GitLabDiff(oldPath: path, newPath: path, aMode: "0", bMode: "100644", diff: body,
                          newFile: true, renamedFile: false, deletedFile: false)
    }

    private static func deleted(_ path: String, _ lines: [String]) -> GitLabDiff {
        let body = "@@ -1,\(lines.count) +0,0 @@\n" + lines.map { "-" + $0 }.joined(separator: "\n") + "\n"
        return GitLabDiff(oldPath: path, newPath: path, aMode: "100644", bMode: "0", diff: body,
                          newFile: false, renamedFile: false, deletedFile: true)
    }

    // MARK: payments/api!412: webhook retries

    static let webhookRetries: [GitLabDiff] = [
        modified("app/webhooks/delivery.py", """
        @@ -1,8 +1,10 @@
         import logging
        +import time
         
         import httpx
         
        +from app.webhooks.backoff import backoff_delays
         from app.webhooks.models import Delivery, DeliveryStatus
         
         logger = logging.getLogger(__name__)
        @@ -24,18 +26,30 @@ class WebhookDeliverer:
         
             def deliver(self, delivery: Delivery) -> DeliveryStatus:
        -        response = self._client.post(
        -            delivery.endpoint_url,
        -            json=delivery.payload,
        -            timeout=self._timeout,
        -        )
        -        if response.is_success:
        -            return DeliveryStatus.DELIVERED
        -        logger.warning("Delivery %s failed with %s", delivery.id, response.status_code)
        -        return DeliveryStatus.FAILED
        +        for attempt, delay in enumerate(backoff_delays(self._max_attempts)):
        +            try:
        +                response = self._client.post(
        +                    delivery.endpoint_url,
        +                    json=delivery.payload,
        +                    timeout=self._timeout,
        +                )
        +            except httpx.TransportError:
        +                response = None
        +            if response is not None and response.is_success:
        +                return DeliveryStatus.DELIVERED
        +            if response is not None and 400 <= response.status_code < 500:
        +                # TODO: retry 429s instead of treating them as permanent failures
        +                return DeliveryStatus.FAILED
        +            print(f"retrying delivery {delivery.id} attempt {attempt}")
        +            time.sleep(delay)
        +        logger.warning("Delivery %s gave up after %d attempts", delivery.id, self._max_attempts)
        +        return DeliveryStatus.FAILED
         
             def _signature(self, payload: bytes) -> str:
                 return hmac.new(self._secret, payload, hashlib.sha256).hexdigest()
        """),
        added("app/webhooks/backoff.py", [
            "import random",
            "from collections.abc import Iterator",
            "",
            "",
            "def backoff_delays(max_attempts: int, base: float = 0.5, cap: float = 30.0) -> Iterator[float]:",
            "    \"\"\"Yields full-jitter exponential backoff delays.\"\"\"",
            "    for attempt in range(max_attempts):",
            "        yield random.uniform(0, min(cap, base * 2 ** attempt))",
        ]),
        modified("tests/webhooks/test_delivery.py", """
        @@ -40,6 +40,22 @@ def test_delivers_successfully(deliverer, delivery, respx_mock):
             assert deliverer.deliver(delivery) is DeliveryStatus.DELIVERED
         
         
        +def test_retries_server_errors(deliverer, delivery, respx_mock, monkeypatch):
        +    monkeypatch.setattr("time.sleep", lambda _: None)
        +    route = respx_mock.post(delivery.endpoint_url).mock(
        +        side_effect=[httpx.Response(503), httpx.Response(200)]
        +    )
        +    assert deliverer.deliver(delivery) is DeliveryStatus.DELIVERED
        +    assert route.call_count == 2
        +
        +
        +def test_does_not_retry_client_errors(deliverer, delivery, respx_mock):
        +    route = respx_mock.post(delivery.endpoint_url).mock(return_value=httpx.Response(410))
        +    assert deliverer.deliver(delivery) is DeliveryStatus.FAILED
        +    assert route.call_count == 1
        +
        +
         def test_signature_is_stable(deliverer):
             assert deliverer._signature(b"{}") == deliverer._signature(b"{}")
        """),
        GitLabDiff(oldPath: "poetry.lock", newPath: "poetry.lock", aMode: "100644", bMode: "100644", diff: "",
                   newFile: false, renamedFile: false, deletedFile: false, generatedFile: true, collapsed: true),
    ]

    // MARK: web/storefront!1873: saved carts

    static let savedCarts: [GitLabDiff] = [
        added("src/cart/savedCarts.ts", [
            "import { api } from '../api/client';",
            "import type { Cart } from './types';",
            "",
            "export async function saveCart(cart: Cart, name: string): Promise<string> {",
            "  const response = await api.post('/saved-carts', { name, items: cart.items });",
            "  console.log('saved cart', response.data.id);",
            "  return response.data.id;",
            "}",
            "",
            "export async function restoreCart(id: string): Promise<Cart> {",
            "  const response = await api.get(`/saved-carts/${id}`);",
            "  return { items: response.data.items, currency: response.data.currency };",
            "}",
        ]),
        modified("src/checkout/CheckoutPage.tsx", """
        @@ -12,6 +12,7 @@ import { OrderSummary } from './OrderSummary';
         import { PaymentForm } from './PaymentForm';
         import { useCart } from '../cart/useCart';
        +import { saveCart } from '../cart/savedCarts';
         
         export function CheckoutPage() {
           const { cart } = useCart();
        @@ -38,6 +39,13 @@ export function CheckoutPage() {
               <OrderSummary cart={cart} />
               <PaymentForm onSubmit={placeOrder} />
        +      <button
        +        type="button"
        +        onClick={() => saveCart(cart, `Cart ${new Date().toLocaleDateString()}`)}
        +      >
        +        Save for later
        +      </button>
             </main>
           );
         }
        """),
        GitLabDiff(oldPath: "src/cart/cartStore.ts", newPath: "src/cart/store/cartStore.ts", aMode: "100644", bMode: "100644", diff: """
        @@ -1,4 +1,4 @@
        -import type { Cart } from './types';
        +import type { Cart } from '../types';
         
         export const emptyCart: Cart = { items: [], currency: 'USD' };
         
        """, newFile: false, renamedFile: true, deletedFile: false),
        GitLabDiff(oldPath: "public/images/saved-cart-empty.png", newPath: "public/images/saved-cart-empty.png", aMode: "0", bMode: "100644",
                   diff: "Binary files /dev/null and b/public/images/saved-cart-empty.png differ\n",
                   newFile: true, renamedFile: false, deletedFile: false),
    ]

    // MARK: platform/infra!77: Terraform provider bump

    static let terraformBump: [GitLabDiff] = [
        modified("terraform/versions.tf", """
        @@ -3,7 +3,7 @@ terraform {
           required_providers {
             aws = {
               source  = "hashicorp/aws"
        -      version = "~> 4.67"
        +      version = "~> 5.31"
             }
           }
         }
        """),
        modified(".terraform.lock.hcl", """
        @@ -2,9 +2,9 @@
         # Manual edits may be lost in future updates.
         
         provider "registry.terraform.io/hashicorp/aws" {
        -  version     = "4.67.0"
        -  constraints = "~> 4.67"
        +  version     = "5.31.0"
        +  constraints = "~> 5.31"
           hashes = [
        -    "h1:5Zfo3GfRSWBaXs4TGQNOflr1XaYj6pRnVJLX5VAjFX4=",
        +    "h1:WwgMbMOhZblxZTdjHeJf9XB2/hcSHHmpuywLxuTWYw0=",
           ]
         }
        """, generated: true),
    ]

    // MARK: payments/api!415: ledger refactor (large diff, deletion, pure rename)

    static let ledgerRefactor: [GitLabDiff] = [
        modified("app/ledger/reconcile.py", largeReconcileDiff),
        deleted("app/ledger/legacy_reconcile.py", [
            "from app.ledger.models import Entry",
            "",
            "",
            "def reconcile(entries: list[Entry]) -> list[Entry]:",
            "    unmatched = []",
            "    for entry in entries:",
            "        if not entry.matched:",
            "            unmatched.append(entry)",
            "    return unmatched",
        ]),
        GitLabDiff(oldPath: "docs/ledger.md", newPath: "docs/ledger/overview.md", aMode: "100644", bMode: "100644", diff: "",
                   newFile: false, renamedFile: true, deletedFile: false),
    ]

    /// About 500 lines, over the default 400-line collapse threshold.
    private static let largeReconcileDiff: String = {
        var lines = ["@@ -1,3 +1,500 @@ ", " from decimal import Decimal", " ", " from app.ledger.models import Entry"]
        for index in 0..<62 {
            lines += [
                "+",
                "+",
                "+def match_rule_\(index)(entry: Entry, candidate: Entry) -> bool:",
                "+    \"\"\"Rule \(index): amounts within tolerance and same counterparty.\"\"\"",
                "+    if entry.counterparty_id != candidate.counterparty_id:",
                "+        return False",
                "+    return abs(entry.amount - candidate.amount) <= Decimal(\"0.0\(index % 10)\")",
                "+",
            ]
        }
        return lines.joined(separator: "\n") + "\n"
    }()

    // MARK: web/storefront!1880: currency rounding

    static let currencyRounding: [GitLabDiff] = [
        modified("src/orders/totals.ts", """
        @@ -1,12 +1,16 @@
        +const MINOR_UNITS: Record<string, number> = { USD: 2, EUR: 2, JPY: 0, KWD: 3 };
        +
        +function roundToMinorUnits(amount: number, currency: string): number {
        +  const digits = MINOR_UNITS[currency] ?? 2;
        +  const factor = 10 ** digits;
        +  return Math.round(amount * factor) / factor;
        +}
        +
         export function orderTotal(lines: OrderLine[], currency: string): number {
        -  const subtotal = lines.reduce((sum, line) => sum + line.price * line.quantity, 0);
        -  const tax = subtotal * TAX_RATE;
        -  return Math.round((subtotal + tax) * 100) / 100;
        +  const subtotal = lines.reduce(
        +    (sum, line) => sum + roundToMinorUnits(line.price * line.quantity, currency),
        +    0,
        +  );
        +  return roundToMinorUnits(subtotal + subtotal * TAX_RATE, currency);
         }
        \\ No newline at end of file
        """),
        modified("src/orders/totals.test.ts", """
        @@ -8,4 +8,14 @@ describe('orderTotal', () => {
           it('adds tax', () => {
             expect(orderTotal([{ price: 10, quantity: 1 }], 'USD')).toBe(10.8);
           });
        +
        +  it('rounds yen to whole units', () => {
        +    expect(orderTotal([{ price: 333.3, quantity: 3 }], 'JPY')).toBe(1080);
        +  });
        +
        +  it('keeps three decimals for dinar', () => {
        +    expect(orderTotal([{ price: 1.2345, quantity: 1 }], 'KWD')).toBe(1.333);
        +  });
         });
        """),
    ]

    // MARK: platform/infra!80: Vault rotation (seeds the secret check)

    static let vaultRotation: [GitLabDiff] = [
        modified("deploy/staging/db.tf", """
        @@ -14,8 +14,13 @@ resource "aws_db_instance" "staging" {
           engine         = "postgres"
           engine_version = "15.4"
           instance_class = "db.t3.medium"
        -  username       = "app"
        -  password       = var.db_password
        +  username       = data.vault_generic_secret.db.data["username"]
        +  password       = data.vault_generic_secret.db.data["password"]
        +}
        +
        +provider "aws" {
        +  access_key = "AKIAIOSFODNN7EXAMPLE"
        +  region     = "us-east-1"
         }
        """),
        added("deploy/staging/vault.tf", [
            "data \"vault_generic_secret\" \"db\" {",
            "  path = \"secret/staging/postgres\"",
            "}",
        ]),
    ]

    // MARK: web/storefront!1884: lazy images (GitLab overflow)

    static let lazyImages: [GitLabDiff] = [
        modified("src/components/ProductImage.tsx", """
        @@ -5,9 +5,11 @@ type Props = { src: string; alt: string; width: number; height: number };
         export function ProductImage({ src, alt, width, height }: Props) {
           return (
             <img
               src={src}
               alt={alt}
               width={width}
               height={height}
        +      loading="lazy"
        +      decoding="async"
             />
           );
         }
        """),
        GitLabDiff(oldPath: "src/generated/imageManifest.json", newPath: "src/generated/imageManifest.json", aMode: "100644", bMode: "100644",
                   diff: "", newFile: false, renamedFile: false, deletedFile: false, generatedFile: true, collapsed: true, tooLarge: true),
    ]

    // MARK: payments/api!420: refund idempotency

    static let refundIdempotency: [GitLabDiff] = [
        modified("app/refunds/api.py", """
        @@ -18,10 +18,19 @@ router = APIRouter(prefix="/refunds")
         
         
         @router.post("/", status_code=201)
        -def create_refund(body: RefundRequest, db: Session = Depends(get_db)) -> RefundResponse:
        +def create_refund(
        +    body: RefundRequest,
        +    idempotency_key: str = Header(alias="Idempotency-Key"),
        +    db: Session = Depends(get_db),
        +) -> RefundResponse:
        +    existing = find_by_key(db, idempotency_key)
        +    if existing is not None:
        +        return RefundResponse.from_orm(existing)
             refund = Refund(payment_id=body.payment_id, amount=body.amount)
             db.add(refund)
        +    remember_key(db, idempotency_key, refund)
             db.commit()
             return RefundResponse.from_orm(refund)
        """),
        added("app/refunds/idempotency.py", [
            "from sqlalchemy.orm import Session",
            "",
            "from app.refunds.models import IdempotencyKey, Refund",
            "",
            "",
            "def find_by_key(db: Session, key: str) -> Refund | None:",
            "    row = db.get(IdempotencyKey, key)",
            "    return row.refund if row else None",
            "",
            "",
            "def remember_key(db: Session, key: str, refund: Refund) -> None:",
            "    # FIXME: keys never expire",
            "    db.add(IdempotencyKey(key=key, refund=refund))",
        ]),
        added("migrations/0042_idempotency_keys.sql", [
            "CREATE TABLE idempotency_keys (",
            "    key TEXT PRIMARY KEY,",
            "    refund_id BIGINT NOT NULL REFERENCES refunds(id),",
            "    created_at TIMESTAMPTZ NOT NULL DEFAULT now()",
            ");",
        ]),
    ]
}
