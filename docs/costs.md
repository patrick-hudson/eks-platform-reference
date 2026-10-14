# AWS cost estimates

[Repository overview](../README.md) · [Deployment](deployment.md) · [Cleanup](cleanup.md)

Estimate checked on October 14, 2026, for Linux on-demand instances in the sample
region, 730 hours per month, and the desired node counts. No free-tier credits,
Savings Plans, taxes, or support plan are included. Monitoring runs on the listed
nodes; there are no extra EC2 monitoring servers.

| Component | Dev / month | Prod / month | Basis |
| --- | ---: | ---: | --- |
| EKS control plane | $73.00 | $73.00 | One cluster at $0.10/hour |
| Worker nodes | $60.74 | $210.24 | Two at $0.0416/hour; three at $0.096/hour |
| Node root disks | $4.80 | $7.20 | 30 GiB gp3 per node at $0.08/GiB-month |
| Monitoring disks | $1.20 | $2.80 | 15 / 35 GiB total gp3 |
| NAT gateways | $32.85 | $98.55 | One / three at $0.045/hour |
| NAT public IPv4 | $3.65 | $10.95 | One / three at $0.005/IP-hour |
| Grafana ALB | $16.43 | $16.43 | One at $0.0225/hour |
| ALB public IPv4 | $7.30 | $10.95 | At least one address per enabled zone: two / three |
| ALB capacity allowance | $5.84 | $5.84 | Budget assumption: average one LCU at $0.008/LCU-hour |
| ACM certificate | $0 | $0 | Non-exportable public certificate used by ALB |
| Route 53 alias record | $0 additional | $0 additional | Existing zone; alias queries to ELB are free |
| **Estimated subtotal** | **$205.80** | **$435.96** | Before usage costs below |

The existing `hudson.tf` hosted zone costs $0.50/month once, not per environment;
it is already being paid for. Domain registration and renewal are separate.
State storage and S3 requests are usually well under $1/month for this project.
CloudWatch control-plane log ingestion and storage depend on traffic; allow a
few dollars initially and measure it. A reasonable light-use budget is roughly
**$210–225/month for dev** and **$440–465/month for prod**, or **$650–690/month
for both**. These are budget estimates, not limits or a bill guarantee.

For a short verification run, use these subtotal estimates:

| Runtime | Dev | Prod | Both |
| --- | ---: | ---: | ---: |
| 3 hours | $0.85 | $1.79 | $2.64 |
| 6 hours | $1.69 | $3.58 | $5.27 |
| 24 hours | $6.77 | $14.33 | $21.10 |

Allow **$2–3 for a short dev test** or **$8–10 for a day of dev**, including some
startup downloads and logs. Those allowances assume light traffic and successful
cleanup; they are not caps. Timing starts when AWS resources are provisioned,
including time spent waiting for a deployment or teardown.

Public Grafana adds about **$29.57/month in dev** or **$33.22/month in prod**,
including the one-LCU allowance and minimum public IPs. Capacity and IP counts
can grow under load. Without the LCU allowance, the fixed ingress floor is about
$23.73 / $27.38 per month. A 24-hour dev run is about **$6.77** at the subtotal
rate; prod is about **$14.33**, before variable charges. There is no separate
one-time EKS provisioning fee. Deployment, idle time, and teardown all count.

Add $0.045 for each GB processed by NAT, plus applicable internet and cross-zone
data transfer. Image pulls during first startup use NAT too. Dev's shared NAT
makes cross-zone charges more likely. Burstable CPU credit use can add EC2
charges. Extra nodes cost their instance rate and root disk storage. Retained
PVCs, snapshots, or ALBs left after a failed teardown continue to cost money.
If a cluster enters extended Kubernetes support, EKS's price rises to
$0.60/hour, adding $365/month; this configuration opts into STANDARD support.

Sources: [EKS](https://aws.amazon.com/eks/pricing/),
[EC2 Linux regional rate data](https://b0.p.awsstatic.com/pricing/2.0/meteredUnitMaps/ec2/USD/current/ec2-ondemand-without-sec-sel/US%20East%20(N.%20Virginia)/Linux/index.json),
[EBS](https://aws.amazon.com/ebs/pricing/),
[NAT and public IPv4](https://aws.amazon.com/vpc/pricing/),
[ALB](https://aws.amazon.com/elasticloadbalancing/pricing/),
[ACM](https://aws.amazon.com/certificate-manager/pricing/), and
[Route 53](https://aws.amazon.com/route53/pricing/).
