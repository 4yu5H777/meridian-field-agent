// Shared test data. Shaped exactly like meridian.order_summary() output for
// the Cetimer + ORS Orange order from db/checks-intake.sql.
export function sampleSummary(over: Record<string, unknown> = {}) {
  return {
    order_id: 81, status: 'awaiting_confirmation',
    chemist: { code: 'CH-10', name: 'Singh Medical Agency', locality: 'Sector 18' },
    lines: [
      { line_no: 1, product: 'Cetimer 10 Tablet', pack: 'strip of 10', qty: 10, unit_price_paise: 2000, gross_paise: 20000,
        free_qty: 0, discount_paise: 1000, line_total_paise: 19000, scheme: 'Cetimer 10: 5% off' },
      { line_no: 2, product: 'Meridian ORS Orange', pack: '21 g sachet', qty: 6, unit_price_paise: 2200, gross_paise: 13200,
        free_qty: 3, discount_paise: 0, line_total_paise: 13200, scheme: 'ORS Orange: buy 2 get 1 free' },
    ],
    total_paise: 32200, is_off_route: false, duplicate: null,
    credit: { limit_paise: 20000000, owed_paise: 4023600, over_limit: false, manager_name: 'Kavita Srivastava' },
    confirmation: { code: '3867', total_paise: 32200, expires_ist: '14:09' },
    ...over,
  };
}
