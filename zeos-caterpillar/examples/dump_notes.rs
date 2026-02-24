use std::fs;
use zeos_caterpillar::wallet::Wallet;
use zeos_caterpillar::eosio::Name;
use zeos_caterpillar::constants::MEMO_CHANGE_NOTE;

fn decode_name(raw: u64) -> String {
    if raw == 0 { return "(none)".to_string(); }
    Name(raw).to_string()
}

fn decode_symbol(sym_raw: u64) -> String {
    let precision = sym_raw & 0xFF;
    let mut name_bytes = Vec::new();
    let mut val = sym_raw >> 8;
    while val > 0 {
        name_bytes.push((val & 0xFF) as u8);
        val >>= 8;
    }
    let name_str: String = name_bytes.iter().map(|&b| b as char).collect();
    format!("{},{}", precision, name_str)
}

fn format_amount(amount: u64, sym_raw: u64) -> String {
    let precision = (sym_raw & 0xFF) as u32;
    let divisor = 10u64.pow(precision);
    let whole = amount / divisor;
    let frac = amount % divisor;
    let mut name_bytes = Vec::new();
    let mut val = sym_raw >> 8;
    while val > 0 {
        name_bytes.push((val & 0xFF) as u8);
        val >>= 8;
    }
    let name_str: String = name_bytes.iter().map(|&b| b as char).collect();
    format!("{}.{:0>width$} {}", whole, frac, name_str, width = precision as usize)
}

fn main() {
    let path = std::env::args().nth(1).unwrap_or_else(|| {
        "data/cloak.wallet".to_string()
    });

    let data = fs::read(&path).expect(&format!("Failed to read wallet file: {}", path));
    let wallet = Wallet::read(&mut &data[..]).expect("Failed to parse wallet");

    println!("=== WALLET DUMP ===");
    println!("Leaf count: {}", wallet.leaf_count());
    println!("Auth count: {}", wallet.auth_count());
    println!();

    let unspent = wallet.unspent_notes();
    let mut ft_total: u64 = 0;
    println!("UNSPENT NOTES ({} total):", unspent.len());
    for (i, note) in unspent.iter().enumerate() {
        let n = note.note();
        let is_at = n.symbol().raw() == 0 && n.amount() == 0;
        let is_change = n.memo().eq(&MEMO_CHANGE_NOTE);

        if is_at {
            println!("  [{}] AUTH TOKEN  contract={} block={} ts={}",
                i, decode_name(n.contract().raw()), note.block_num(), note.block_ts());
        } else if n.symbol().raw() == 0 && n.amount() != 0 {
            println!("  [{}] NFT uid={}  contract={} block={} ts={}",
                i, n.amount(), decode_name(n.contract().raw()), note.block_num(), note.block_ts());
        } else {
            ft_total += n.amount();
            println!("  [{}] {} @ {}  account={}  leaf={} block={} ts={}{}",
                i,
                format_amount(n.amount(), n.symbol().raw()),
                decode_name(n.contract().raw()),
                decode_name(n.account().raw()),
                if is_at { 0 } else { note.position() },
                note.block_num(),
                note.block_ts(),
                if is_change { "  [CHANGE]" } else { "" },
            );
            // Dump memo if non-empty and non-change
            let memo_str = n.memo_string();
            if !memo_str.is_empty() && !is_change {
                println!("       memo: {:?}", &memo_str[..memo_str.len().min(80)]);
            }
        }
    }
    println!();
    println!("FT TOTAL from unspent: {} (raw units)", ft_total);
    println!("  = {} CLOAK", ft_total as f64 / 10000.0);

    println!();
    let balances = wallet.balances();
    println!("BALANCES ({} entries):", balances.len());
    for b in &balances {
        println!("  {}", serde_json::to_string(b).unwrap());
    }

    // Full JSON dump for spent/outgoing analysis
    let json = wallet.to_json(false);
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    if let Some(spent) = parsed.get("spent_notes").and_then(|v| v.as_array()) {
        println!();
        println!("SPENT NOTES ({} total):", spent.len());
        for (i, note_ex) in spent.iter().enumerate() {
            if let Some(note) = note_ex.get("note") {
                let asset = note.get("asset").and_then(|a| a.as_str()).unwrap_or("?");
                let account_raw = note.get("account").and_then(|a| a.as_u64()).unwrap_or(0);
                let block_num = note_ex.get("block_num").and_then(|v| v.as_u64()).unwrap_or(0);
                let block_ts = note_ex.get("block_ts").and_then(|v| v.as_u64()).unwrap_or(0);
                let leaf = note_ex.get("leaf_idx_arr").and_then(|v| v.as_u64()).unwrap_or(0);
                let header = note.get("header").and_then(|v| v.as_u64()).unwrap_or(0);
                println!("  [{}] {}  account={} leaf={} block={} ts={} header={}",
                    i, asset, decode_name(account_raw), leaf, block_num, block_ts, header);
            }
        }
    }

    if let Some(outgoing) = parsed.get("outgoing_notes").and_then(|v| v.as_array()) {
        println!();
        println!("OUTGOING NOTES ({} total):", outgoing.len());
        for (i, note_ex) in outgoing.iter().enumerate() {
            if let Some(note) = note_ex.get("note") {
                let asset = note.get("asset").and_then(|a| a.as_str()).unwrap_or("?");
                let account_raw = note.get("account").and_then(|a| a.as_u64()).unwrap_or(0);
                let block_num = note_ex.get("block_num").and_then(|v| v.as_u64()).unwrap_or(0);
                let block_ts = note_ex.get("block_ts").and_then(|v| v.as_u64()).unwrap_or(0);
                let leaf = note_ex.get("leaf_idx_arr").and_then(|v| v.as_u64()).unwrap_or(0);
                let header = note.get("header").and_then(|v| v.as_u64()).unwrap_or(0);
                println!("  [{}] {}  account={} leaf={} block={} ts={} header={}",
                    i, asset, decode_name(account_raw), leaf, block_num, block_ts, header);
            }
        }
    }

    println!();
    println!("=== SUMMARY ===");
    println!("Received (unspent + spent FTs): explains how we got to current balance");
    println!("  Unspent FTs: {}", unspent.iter().filter(|n| n.note().symbol().raw() != 0).count());
    println!("  Spent FTs:   {}", parsed.get("spent_notes").and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0));
    println!("  Outgoing:    {}", parsed.get("outgoing_notes").and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0));
}
