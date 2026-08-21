# Lab Activity 2 — Time-Travel Analytics for a Food-Delivery Platform

GitHub repository : https://github.com/innith/ssd_lab_activity_2

## Assumptions
- OrderID and OrderRequestorID are VARCHAR(20). PartnerID is '' when there is no partner.
- Each order has one PIN code, so we use MIN(PINCode).
- The first PendingAssignment time is treated as the order time.
- For reassigned orders, all results are given to the final partner.
- Delivery time is calculated by following the order step by step: Accept → Pickup → Arrive → Deliver. If something never happens, we leave the time as `NULL`.
- Status totals count events, not unique orders.
- `requestorstatistics` show the overall history of each customer.

## KPI Rationale
- TotalOrdersPlaced tells us how many orders a customer made.
- TotalDelivered tells us how many were successfully delivered.
- Cancellation and failure rates show possible problems.
- Average delivery time shows how quickly orders are delivered.
- Most-used PIN shows the customer's main area.
- Most-used partner shows which delivery partner they usually get.

## Cursor vs. Set-Based Processing
- The cursor processes orders one at a time.
- For each order, it checks the events in order and calculates the time between them.
- A set-based query processes many orders together, so it is usually faster. But orders that got reassigned can have multiple "Accepted" events, and matching each "Pending" to the correct one gets trickier without the cursor's step-by-step order.
- A self-join or a LEAD() window function partitioned by OrderID could replace it, and would likely run faster since it avoids one query per order.
