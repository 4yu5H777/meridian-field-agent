// Writes the spreadsheet samples in samples/ (node scripts/make-sample-sheets.ts).
import { writeFileSync } from 'node:fs';
import { xlsx } from '../tests/mediaFixtures.ts';

// The brief's awkward sheet: 60 lines for one chemist, the chemist cell merged
// (blank below the first row), price columns, and a total row that does not add up.
const names = ['Cetimer', 'ORS orange', 'Merilax', 'Kofset DX', 'Gasomer'];
const po: (string | number)[][] = [['Purchase order - Singh Medical Agency - Sector 18'], [''], ['Chemist', 'Product', 'Qty', 'Rate', 'Amount']];
for (let i = 0; i < 60; i++) po.push([i === 0 ? 'Singh Medical Agency' : '', names[i % names.length], (i % 4) + 1, 20, ((i % 4) + 1) * 20]);
po.push(['Total', '', 170, '', 9999]);
writeFileSync('samples/purchase-order-60-lines.xlsx', xlsx(po));

// Hindi headers, two chemists, a number word and a Devanagari digit.
writeFileSync('samples/hindi-order.xlsx', xlsx([
  ['दुकान', 'दवा', 'मात्रा'],
  ['Singh Medical Agency', 'सेटीमर', '10'],
  ['Singh Medical Agency', 'ओआरएस ऑरेंज', 'छह'],
  ['Om Sai Medicos', 'Merilax', '४'],
], { inline: true }));

// Needs the rep's answer: no chemist anywhere, a vague quantity, loose tablets.
writeFileSync('samples/needs-clarification.csv', 'Product,Qty,Unit\nCetimer,kuch,\nMeridol 650,20,tablets\nORS orange,6,\n');
writeFileSync('samples/order.csv', 'Chemist,Product,Qty\nSingh Medical Agency,Cetimer,10\nSingh Medical Agency,ORS orange,6\n');
console.log('written');
