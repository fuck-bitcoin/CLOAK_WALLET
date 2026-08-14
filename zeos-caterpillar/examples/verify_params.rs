use bellman::gadgets::test::TestConstraintSystem;
use bellman::groth16::{create_random_proof, prepare_verifying_key, verify_proof, Parameters};
use bellman::Circuit;
use blstrs::{Bls12, Scalar};
use rand::rngs::OsRng;
use sha2::{Digest, Sha256};
use std::env;
use std::fs::File;
use std::io::{self, BufReader, Read};
use std::path::{Path, PathBuf};
use zeos_caterpillar::circuit::{
    mint::Mint, output::Output, spend::Spend, spend_output::SpendOutput,
};
use zeos_caterpillar::constants::MERKLE_TREE_DEPTH;
use zeos_caterpillar::contract::AffineVerifyingKeyBytesLE;
use zeos_caterpillar::eosio::ExtendedAsset;
use zeos_caterpillar::note::Note;
use zeos_caterpillar::value::ValueCommitTrapdoor;

struct Expected {
    name: &'static str,
    size: u64,
    params_sha256: &'static str,
    verifying_key_sha256: &'static str,
}

const EXPECTED: &[Expected] = &[
    Expected {
        name: "mint.params",
        size: 15_600_764,
        params_sha256: "502c145d1329e83a72f52b0a3091237b54b238178d05d9e3e484c909a597107a",
        verifying_key_sha256: "64d3fd942cc195a3a274c07c4059dffb7b1cdccae04cdc09b9ee9e79bf3ac40e",
    },
    Expected {
        name: "spend-output.params",
        size: 116_049_020,
        params_sha256: "e187e4e0690fc1c053f171b14d9353405d554c07b2a6777d2fe93a4c4c4a50e2",
        verifying_key_sha256: "90a69e8bf2a40df9e29b79de51749623cc5fc70c2ec3dd96953c9d8130273c38",
    },
    Expected {
        name: "spend.params",
        size: 114_333_500,
        params_sha256: "0b37b4873684e3fefb459eabd59d1da2a8be2ffadf261401eaa4d843a280b33c",
        verifying_key_sha256: "af9dafc133cf2453904e04ae1b17bce885e2476eed5cf458cff61005c5369540",
    },
    Expected {
        name: "output.params",
        size: 3_070_652,
        params_sha256: "7c6b056ed748e842739b2148496d6dbfc387463f98c3b4bddb08c1be60a9aa6b",
        verifying_key_sha256: "2963b173d0fa297441500ef075654063feff8979d5bc5464313c9eae70484e52",
    },
];

fn sha256_file(path: &Path) -> io::Result<String> {
    let mut file = BufReader::new(File::open(path)?);
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 1024 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hex::encode(hasher.finalize()))
}

fn verify_file(directory: &Path, expected: &Expected) -> Result<(), String> {
    let path = directory.join(expected.name);
    let metadata = path
        .metadata()
        .map_err(|error| format!("{}: {error}", path.display()))?;
    if metadata.len() != expected.size {
        return Err(format!(
            "{}: expected {} bytes, found {}",
            path.display(),
            expected.size,
            metadata.len()
        ));
    }

    let params_hash = sha256_file(&path).map_err(|error| error.to_string())?;
    if params_hash != expected.params_sha256 {
        return Err(format!("{}: parameter SHA-256 mismatch", path.display()));
    }

    let file = BufReader::new(File::open(&path).map_err(|error| error.to_string())?);
    let parameters = Parameters::<blstrs::Bls12>::read(file, false)
        .map_err(|error| format!("{}: Groth16 parse failed: {error}", path.display()))?;
    let affine = AffineVerifyingKeyBytesLE::from(parameters.vk);
    let vk_hash = hex::encode(Sha256::digest(&affine.0));
    if vk_hash != expected.verifying_key_sha256 {
        return Err(format!(
            "{}: derived verifying-key SHA-256 mismatch",
            path.display()
        ));
    }

    println!(
        "verified {} ({} bytes, params {}, VK {})",
        expected.name, expected.size, params_hash, vk_hash
    );
    Ok(())
}

fn verify_representative_proof<C>(
    params_path: &Path,
    circuit_name: &str,
    proof_circuit: C,
    input_circuit: C,
    expected_constraints: usize,
    expected_circuit_hash: &str,
    input_names: &[&str],
) -> Result<(), String>
where
    C: Circuit<Scalar>,
{
    let mut cs = TestConstraintSystem::<Scalar>::new();
    input_circuit
        .synthesize(&mut cs)
        .map_err(|error| format!("{circuit_name}: witness synthesis failed: {error}"))?;
    if !cs.is_satisfied() {
        return Err(format!(
            "{circuit_name}: representative witness is unsatisfied at {}",
            cs.which_is_unsatisfied().unwrap_or("unknown constraint")
        ));
    }
    if cs.num_constraints() != expected_constraints || cs.hash() != expected_circuit_hash {
        return Err(format!(
            "{circuit_name}: circuit identity mismatch (constraints {}, hash {})",
            cs.num_constraints(),
            cs.hash()
        ));
    }
    if cs.num_inputs() != input_names.len() + 1 {
        return Err(format!(
            "{circuit_name}: expected {} public inputs, synthesized {}",
            input_names.len(),
            cs.num_inputs() - 1
        ));
    }
    let public_inputs = input_names
        .iter()
        .enumerate()
        .map(|(index, name)| cs.get_input(index + 1, name))
        .collect::<Vec<_>>();

    let params = Parameters::<Bls12>::read(
        BufReader::new(File::open(params_path).map_err(|error| error.to_string())?),
        false,
    )
    .map_err(|error| format!("{circuit_name}: parameter parse failed: {error}"))?;
    let started = std::time::Instant::now();
    let proof = create_random_proof(proof_circuit, &params, &mut OsRng)
        .map_err(|error| format!("{circuit_name}: proof creation failed: {error}"))?;
    verify_proof(&prepare_verifying_key(&params.vk), &proof, &public_inputs)
        .map_err(|error| format!("{circuit_name}: proof verification failed: {error}"))?;
    println!(
        "created and verified representative {circuit_name} proof in {} ms",
        started.elapsed().as_millis()
    );
    Ok(())
}

fn depth_12_auth_path() -> Vec<Option<([u8; 32], bool)>> {
    (0..MERKLE_TREE_DEPTH)
        .map(|level| Some(([(level + 1) as u8; 32], false)))
        .collect()
}

fn verify_representative_proofs(directory: &Path) -> Result<(), String> {
    let mut rng = OsRng;

    let (mint_sk, _, mint_note) = Note::dummy(
        &mut rng,
        None,
        ExtendedAsset::from_string("5.0000 CLOAK@thezeostoken"),
    );
    let mint_pgk = mint_sk.proof_generation_key();
    let mint = || Mint {
        account: Some(mint_note.account().raw()),
        auth_hash: Some([0; 4]),
        value: Some(mint_note.amount()),
        symbol: Some(mint_note.symbol().raw()),
        contract: Some(mint_note.contract().raw()),
        address: Some(mint_note.address()),
        rcm: Some(mint_note.rcm()),
        proof_generation_key: Some(mint_pgk.clone()),
    };
    verify_representative_proof(
        &directory.join("mint.params"),
        "Mint",
        mint(),
        mint(),
        32_410,
        "ec0c2f7f8c0deb8ffc75ba89a8f9a5bd8d811774f8e11fc95baa93af3f56975c",
        &[
            "commitment/input variable",
            "pack inputs2 contents/input 0",
            "pack inputs3 contents/input 0",
        ],
    )?;

    let (_, _, output_note) = Note::dummy(
        &mut rng,
        None,
        ExtendedAsset::from_string("4.0000 CLOAK@thezeostoken"),
    );
    let output_rscm = jubjub::Fr::from(21u64);
    let output_rcv = ValueCommitTrapdoor::random(&mut rng).inner();
    let output = || Output {
        rcv: Some(output_rcv),
        rscm: Some(output_rscm),
        note_b: Some(output_note.clone()),
    };
    verify_representative_proof(
        &directory.join("output.params"),
        "Output",
        output(),
        output(),
        6_598,
        "5e9206a01732651c033c95b8d68eb1dc51167722372354ff70e3d35fa4f73a92",
        &[
            "symbol commitment/input variable",
            "commitment b/input variable",
            "commitment point/u/input variable",
            "commitment point/v/input variable",
        ],
    )?;

    let (spend_sk, _, spend_note) = Note::dummy(
        &mut rng,
        None,
        ExtendedAsset::from_string("10.0000 CLOAK@thezeostoken"),
    );
    let spend_pgk = spend_sk.proof_generation_key();
    let spend_auth_path = depth_12_auth_path();
    let spend_rscm = jubjub::Fr::from(22u64);
    let spend_rcv = ValueCommitTrapdoor::random(&mut rng).inner();
    let spend = || Spend {
        note_a: Some(spend_note.clone()),
        proof_generation_key: Some(spend_pgk.clone()),
        auth_path: spend_auth_path.clone(),
        rcv: Some(spend_rcv),
        rscm: Some(spend_rscm),
    };
    verify_representative_proof(
        &directory.join("spend.params"),
        "Spend",
        spend(),
        spend(),
        227_170,
        "51e80a7a5d3cd29de9a1f716059888305e3b5e6f6a7fa23485ff2b25289ad651",
        &[
            "anchor/input 0",
            "nullifier/input variable",
            "symbol commitment/input variable",
            "commitment point/u/input variable",
            "commitment point/v/input variable",
        ],
    )?;

    let (spend_output_sk, _, spend_output_note_a) = Note::dummy(
        &mut rng,
        None,
        ExtendedAsset::from_string("10.0000 CLOAK@thezeostoken"),
    );
    let (_, _, spend_output_note_b) = Note::dummy(
        &mut rng,
        None,
        ExtendedAsset::from_string("5.0000 CLOAK@thezeostoken"),
    );
    let spend_output_pgk = spend_output_sk.proof_generation_key();
    let spend_output_auth_path = depth_12_auth_path();
    let spend_output_rscm = jubjub::Fr::from(23u64);
    let spend_output_rcv = ValueCommitTrapdoor::random(&mut rng).inner();
    let spend_output = || SpendOutput {
        note_a: Some(spend_output_note_a.clone()),
        proof_generation_key: Some(spend_output_pgk.clone()),
        auth_path: spend_output_auth_path.clone(),
        rcv: Some(spend_output_rcv),
        rcv_mul: Some(1),
        rscm: Some(spend_output_rscm),
        note_b: Some(spend_output_note_b.clone()),
        value_c: Some(25_000),
        unshielded_outputs_hash: Some([0; 4]),
    };
    verify_representative_proof(
        &directory.join("spend-output.params"),
        "SpendOutput",
        spend_output(),
        spend_output(),
        232_225,
        "9696908251ca22f58e94fb4de3b8a8107d06bef2b1bc85e407ea99d8405c233d",
        &[
            "anchor/input 0",
            "nullifier/input variable",
            "symbol commitment/input variable",
            "commitment b/input variable",
            "cv_net/u/input variable",
            "cv_net/v/input variable",
            "pack inputs7 contents/input 0",
            "pack inputs8 contents/input 0",
        ],
    )?;

    Ok(())
}

fn main() {
    let directory = env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("params/v1.1.0-12"));

    for expected in EXPECTED {
        if let Err(error) = verify_file(&directory, expected) {
            eprintln!("parameter verification failed: {error}");
            std::process::exit(1);
        }
    }

    if let Err(error) = verify_representative_proofs(&directory) {
        eprintln!("production proof verification failed: {error}");
        std::process::exit(1);
    }
}
