// Hindi, English and mixed (Hinglish) input: deterministic helpers that turn
// the way a rep writes a name or a quantity into forms the matcher can use.
// Nothing here decides a match. runIntake looks every variant up with the
// same database matcher and the same thresholds, keeps each candidate's best
// score, and still asks the rep whenever it is not sure.
//
// Pure (no SDK, no database), so it is unit-tested directly.

const DEVANAGARI = /[ऀ-ॿ]/;
export const hasDevanagari = (s: string) => DEVANAGARI.test(s);

// Script of a message, for choosing a reply language. 'mixed' = both scripts,
// or Latin text with common Hindi words (Hinglish).
const HINGLISH = /\b(ka|ki|ke|ko|hai|hain|aur|bhej|bhejo|chahiye|wala|wale|wali|patta|patte|dabba|dabbe|goli|haan|nahi|kal|aaj|liye|karo|kar|do|dena|bhai)\b/i;
export function scriptOf(text: string): 'hindi' | 'english' | 'mixed' {
  const s = typeof text === 'string' ? text : '';
  const deva = (s.match(/[ऀ-ॿ]/g) ?? []).length;
  const latin = (s.match(/[A-Za-z]/g) ?? []).length;
  if (deva > 0 && latin === 0) return 'hindi';
  if (deva > 0) return 'mixed';
  return HINGLISH.test(s) ? 'mixed' : 'english';
}

// ------------------------------------------------------------------ transliteration
// Devanagari -> Latin, the way reps and pharmacists spell names in Latin
// (ि/ी both "i", ु/ू both "u", word-final inherent "a" dropped). Common
// loanwords and surnames go through a small dictionary first, because their
// usual Latin spelling is not phonetic ("मेडिकल" -> "medical", not "medikal").
const WORDS: Record<string, string> = {
  'मेडिकल': 'medical', 'मेडिकल्स': 'medicals', 'मेडिकोज': 'medicos', 'मेडिको': 'medico', 'मेडिकोस': 'medicos',
  'एजेंसी': 'agency', 'एजेन्सी': 'agency', 'एजेंसीज': 'agencies', 'फार्मेसी': 'pharmacy', 'फार्मा': 'pharma',
  'केमिस्ट': 'chemist', 'केमिस्ट्स': 'chemists', 'स्टोर': 'store', 'स्टोर्स': 'stores', 'हॉल': 'hall', 'सेंटर': 'centre',
  'सिरप': 'syrup', 'सीरप': 'syrup', 'टैबलेट': 'tablet', 'टेबलेट': 'tablet', 'टैबलेट्स': 'tablet', 'गोली': 'tablet', 'कैप्सूल': 'capsule',
  'ऑरेंज': 'orange', 'ओरेंज': 'orange', 'संतरा': 'orange', 'लेमन': 'lemon', 'नींबू': 'lemon', 'निम्बू': 'lemon',
  'ड्रॉप्स': 'drops', 'ड्रॉप': 'drops', 'ड्रॉप्स़': 'drops', 'क्रीम': 'cream', 'जेल': 'gel', 'इंजेक्शन': 'injection', 'पाउडर': 'powder',
  'विटामिन': 'vitamin', 'ओआरएस': 'ors', 'डीएक्स': 'dx', 'पी': 'p', 'डी': 'd', 'सी': 'c', 'प्लस': 'plus', 'फोर्ट': 'forte',
  'सिंह': 'singh', 'शर्मा': 'sharma', 'गुप्ता': 'gupta', 'बंसल': 'bansal', 'अग्रवाल': 'agarwal', 'जैन': 'jain', 'वर्मा': 'verma',
  'न्यू': 'new', 'लाइफ': 'life', 'ओम': 'om', 'साई': 'sai', 'श्री': 'shri', 'राम': 'ram', 'कृष्णा': 'krishna', 'गणेश': 'ganesh',
};
const VOWELS: Record<string, string> = {
  'अ': 'a', 'आ': 'aa', 'इ': 'i', 'ई': 'i', 'उ': 'u', 'ऊ': 'u', 'ऋ': 'ri', 'ए': 'e', 'ऐ': 'ai', 'ओ': 'o', 'औ': 'au', 'ऑ': 'o', 'ऍ': 'e',
};
const MATRAS: Record<string, string> = {
  'ा': 'a', 'ि': 'i', 'ी': 'i', 'ु': 'u', 'ू': 'u', 'ृ': 'ri', 'े': 'e', 'ै': 'ai', 'ो': 'o', 'ौ': 'au', 'ॉ': 'o', 'ॅ': 'e',
};
const CONSONANTS: Record<string, string> = {
  'क': 'k', 'ख': 'kh', 'ग': 'g', 'घ': 'gh', 'ङ': 'n', 'च': 'ch', 'छ': 'chh', 'ज': 'j', 'झ': 'jh', 'ञ': 'n',
  'ट': 't', 'ठ': 'th', 'ड': 'd', 'ढ': 'dh', 'ण': 'n', 'त': 't', 'थ': 'th', 'द': 'd', 'ध': 'dh', 'न': 'n',
  'प': 'p', 'फ': 'f', 'ब': 'b', 'भ': 'bh', 'म': 'm', 'य': 'y', 'र': 'r', 'ल': 'l', 'व': 'v',
  'श': 'sh', 'ष': 'sh', 'स': 's', 'ह': 'h', 'क़': 'q', 'ख़': 'kh', 'ग़': 'g', 'ज़': 'z', 'ड़': 'r', 'ढ़': 'rh', 'फ़': 'f', 'य़': 'y',
};
const VIRAMA = '्';
const NUKTA = '़';

function translitWord(word: string): string {
  const w = word.normalize('NFC');
  if (WORDS[w]) return WORDS[w];
  const chars = [...w.normalize('NFD')];       // NFD splits nukta forms into base + ़
  let out = '';
  for (let i = 0; i < chars.length; i++) {
    let ch = chars[i];
    if (chars[i + 1] === NUKTA) { ch = (ch + NUKTA).normalize('NFC'); i++; }
    const d = ch.charCodeAt(0);
    if (d >= 0x0966 && d <= 0x096f) { out += String(d - 0x0966); continue; }
    if (VOWELS[ch]) { out += VOWELS[ch]; continue; }
    if (ch === 'ं' || ch === 'ँ') { out += 'n'; continue; }
    if (ch === 'ः') { out += 'h'; continue; }
    const c = CONSONANTS[ch] ?? CONSONANTS[ch.normalize('NFC')];
    if (c !== undefined) {
      out += c;
      const next = chars[i + 1];
      if (next === VIRAMA) { i++; continue; }                     // conjunct: no vowel
      if (next !== undefined && MATRAS[next] !== undefined) { out += MATRAS[next]; i++; continue; }
      const atEnd = next === undefined || !DEVANAGARI.test(next) || next === 'ं' && i + 2 >= chars.length;
      if (!atEnd) out += 'a';                                      // inherent vowel, dropped at the end of a word
      continue;
    }
    if (MATRAS[ch] !== undefined) { out += MATRAS[ch]; continue; }
    if (!DEVANAGARI.test(ch)) out += ch;                          // Latin, digits, spaces pass through
  }
  return out;
}

export function transliterate(text: string): string {
  if (typeof text !== 'string') return '';
  return text.split(/(\s+)/).map((t) => (hasDevanagari(t) ? translitWord(t) : t)).join('').replace(/\s+/g, ' ').trim();
}

// ------------------------------------------------------------------ filler and pack words
// Words reps put around a name that are never part of one. Whole words only.
const FILLER = new Set([
  'ka', 'ki', 'ke', 'ko', 'se', 'wala', 'wale', 'wali', 'waala', 'waale', 'waali', 'liye', 'bhai', 'please', 'pls', 'plz',
  'order', 'bhejo', 'bhejna', 'chahiye', 'dukaan', 'dukan', 'aur', 'and', 'for', 'to', 'of', 'the',
  'का', 'की', 'के', 'को', 'से', 'वाला', 'वाले', 'वाली', 'लिए', 'भाई', 'ऑर्डर', 'भेजो', 'भेजना', 'चाहिए', 'दुकान', 'और',
]);
const PHRASES = [/\bbhej\s+do\b/gi, /\bde\s+do\b/gi, /\bdedo\b/gi, /\bbhej\s+dena\b/gi, /भेज\s+दो/g, /दे\s+दो/g, /भेज\s+देना/g];
// Pack words: how many, not which product. (Not "patti" / पट्टी: that is also
// the everyday word for a bandage, which is a product.)
const PACKS = new Set([
  'patta', 'patte', 'pattey', 'strip', 'strips', 'dabba', 'dabbe', 'dibba', 'dibbe', 'box', 'boxes',
  'shishi', 'bottle', 'bottles', 'packet', 'packets', 'pack', 'packs', 'pc', 'pcs',
  'पत्ता', 'पत्ते', 'पत्तें', 'डब्बा', 'डब्बे', 'डिब्बा', 'डिब्बे', 'शीशी', 'बोतल', 'बोतलें', 'पैकेट',
]);
// Dosage-form words in Hindi / Hinglish, mapped to the catalogue's word. Never
// removed: "Cetimer syrup" and "Cetimer" are different products.
const FORMS: Record<string, string> = { goli: 'tablet', goliyan: 'tablet', 'गोली': 'tablet', 'गोलियां': 'tablet', sirap: 'syrup', sirup: 'syrup', 'सिरप': 'syrup' };

export function stripFillers(text: string): string {
  if (typeof text !== 'string') return '';
  let s = text.normalize('NFC');
  for (const p of PHRASES) s = s.replace(p, ' ');
  return s.split(/\s+/)
    .filter(Boolean)
    .map((w) => FORMS[w.toLowerCase()] ?? w)
    .filter((w) => !FILLER.has(w.toLowerCase()) && !PACKS.has(w.toLowerCase()))
    .join(' ')
    .trim();
}

// The spellings to look up for one name, most literal first: as written, without
// filler and pack words, and (when it has Hindi script) transliterated. At most 3.
export function nameVariants(text: string): string[] {
  const t = typeof text === 'string' ? text.replace(/\s+/g, ' ').trim() : '';
  if (!t) return [];
  const stripped = stripFillers(t);
  const out = [t, stripped, hasDevanagari(stripped) ? transliterate(stripped) : ''];
  return [...new Set(out.filter((v) => v && v.length >= 2))].slice(0, 3);
}

// ------------------------------------------------------------------ quantities in words
const NUMBER_WORDS: Record<string, number> = {
  ek: 1, one: 1, do: 2, two: 2, teen: 3, tin: 3, three: 3, char: 4, chaar: 4, four: 4, paanch: 5, panch: 5, five: 5,
  chhe: 6, chhah: 6, chah: 6, che: 6, six: 6, saat: 7, sat: 7, seven: 7, aath: 8, ath: 8, eight: 8, nau: 9, nine: 9,
  das: 10, ten: 10, gyarah: 11, gyaarah: 11, eleven: 11, barah: 12, baarah: 12, twelve: 12, terah: 13, thirteen: 13,
  chaudah: 14, fourteen: 14, pandrah: 15, fifteen: 15, solah: 16, sixteen: 16, satrah: 17, seventeen: 17,
  atharah: 18, athaarah: 18, eighteen: 18, unnis: 19, nineteen: 19, bees: 20, bis: 20, twenty: 20, pachees: 25, pachchis: 25,
  tees: 30, thirty: 30, chalis: 40, chaalis: 40, forty: 40, pachas: 50, pachaas: 50, fifty: 50, sau: 100, hundred: 100,
  'एक': 1, 'दो': 2, 'तीन': 3, 'चार': 4, 'पांच': 5, 'पाँच': 5, 'छह': 6, 'छः': 6, 'छे': 6, 'सात': 7, 'आठ': 8, 'नौ': 9, 'दस': 10,
  'ग्यारह': 11, 'बारह': 12, 'तेरह': 13, 'चौदह': 14, 'पंद्रह': 15, 'पन्द्रह': 15, 'सोलह': 16, 'सत्रह': 17, 'अठारह': 18,
  'उन्नीस': 19, 'बीस': 20, 'पच्चीस': 25, 'तीस': 30, 'चालीस': 40, 'पचास': 50, 'सौ': 100,
};
const DOZEN = new Set(['darjan', 'dozen', 'दर्जन']);

// "das", "दस", "ek darjan", "do dozen", "das patta": a whole number, or null.
// Only number words (and optionally one pack word after them); anything else is null.
export function numberFromWords(text: string): number | null {
  if (typeof text !== 'string') return null;
  const words = text.normalize('NFC').toLowerCase().trim().split(/\s+/).filter(Boolean);
  if (words.length === 0 || words.length > 3) return null;
  if (PACKS.has(words[words.length - 1]) && words.length > 1) words.pop();
  if (words.length === 1 && DOZEN.has(words[0])) return 12;
  if (words.length === 1 && NUMBER_WORDS[words[0]] !== undefined) return NUMBER_WORDS[words[0]];
  if (words.length === 2 && NUMBER_WORDS[words[0]] !== undefined && DOZEN.has(words[1])) return NUMBER_WORDS[words[0]] * 12;
  return null;
}

// Every whole number a text states, in digits (either script) or words
// ("10", "१०", "das", "ek darjan"). Used to check a voice note's extracted
// quantities against what was actually said.
export function numbersIn(text: string): Set<number> {
  const out = new Set<number>();
  if (typeof text !== 'string') return out;
  const s = text.normalize('NFC').replace(/[०-९]/g, (d) => String(d.charCodeAt(0) - 0x0966)).toLowerCase();
  for (const m of s.matchAll(/[0-9]+/g)) out.add(Number(m[0]));
  const words = s.split(/[^\p{L}\p{M}]+/u).filter(Boolean);
  for (let i = 0; i < words.length; i++) {
    const pair = i + 1 < words.length ? numberFromWords(`${words[i]} ${words[i + 1]}`) : null;
    if (pair !== null) out.add(pair);
    const single = numberFromWords(words[i]);
    if (single !== null) out.add(single);
  }
  return out;
}
