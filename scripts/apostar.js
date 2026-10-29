// Cachipún · enviar apuestas (crearPartida / unirsePartida) desde Remix
// Uso: abre este archivo en Remix y presiona ▶ Run (arriba del editor).
// La cuenta que firma es la que tengas seleccionada en MetaMask.

const CONTRATO = '0xc80660Ed1Aa19cE6cd0970CDaea8289d884E1a03';

// ---- Cambia solo estas líneas en cada paso -------------------------------
const PASO = 'crear';   // 'crear' (Jugador A) o 'unirse' (Jugador B)
const ID = 1;           // id de la partida (solo para 'unirse')
const COMPROMISO = '0x0a309b2fa89f38142cd7d8aea54397d4bbe9fd582634ed037708b2a5f3ab541a';
const APUESTA_ETH = '0.001';
// ---------------------------------------------------------------------------

const ABI = [
  'function crearPartida(bytes32 compromiso) payable returns (uint256)',
  'function unirsePartida(uint256 id, bytes32 compromiso) payable',
  'function totalPartidas() view returns (uint256)',
];

(async () => {
  const provider = ethers.BrowserProvider
    ? new ethers.BrowserProvider(web3Provider)          // ethers v6
    : new ethers.providers.Web3Provider(web3Provider);  // ethers v5
  const parseEther = ethers.parseEther || ethers.utils.parseEther;

  const signer = await provider.getSigner();
  const cuenta = await signer.getAddress();
  const red = await provider.getNetwork();
  console.log('Cuenta:', cuenta, '| chainId:', red.chainId.toString());
  if (red.chainId.toString() !== '11155111') throw new Error('MetaMask no está en Sepolia');

  const juego = new ethers.Contract(CONTRATO, ABI, signer);
  const opciones = { value: parseEther(APUESTA_ETH) };

  const tx = PASO === 'crear'
    ? await juego.crearPartida(COMPROMISO, opciones)
    : await juego.unirsePartida(ID, COMPROMISO, opciones);

  console.log('Transacción enviada:', tx.hash);
  await tx.wait();
  console.log('Confirmada. Partidas creadas hasta ahora:', (await juego.totalPartidas()).toString());
})().catch((e) => console.log('Error:', e.shortMessage || e.reason || e.message));
