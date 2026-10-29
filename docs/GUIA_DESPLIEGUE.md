# Procedimiento de despliegue y ejecución en Sepolia (Remix + MetaMask)

Mismo flujo de las semanas 7 y 8, con dos cuentas porque el juego necesita dos jugadores.

## 0. Requisitos

- Dos cuentas MetaMask en la red **Sepolia**: Jugador A y Jugador B (pueden ser dos integrantes del equipo o dos cuentas en la misma MetaMask).
- Sepolia ETH en ambas. A necesita más porque paga el despliegue (~2,4 millones de gas). Faucet: `sepolia-faucet.pk910.de`.
- Apuesta sugerida: **0,001 ETH** por jugador.

## 1. Compilar

1. remix.ethereum.org → carpeta `contracts` → New File → `Cachipun.sol` → pegar el contrato.
2. Solidity Compiler → versión **0.8.28 o superior**. En *Advanced Configurations*, EVM version por defecto (cancun o posterior).
3. Compile → check verde.

📷 **Evidencia 1:** Remix con el contrato compilado.

## 2. Desplegar

1. Deploy & Run → ENVIRONMENT: **Injected Provider · MetaMask** → verificar *Sepolia (11155111)*.
2. ACCOUNT: Jugador A.
3. CONTRACT: `Cachipun`. En el campo junto a **Deploy**, `_plazoRevelacion` = **300**.
4. Deploy → confirmar en MetaMask → esperar confirmación → copiar la dirección `0x…` del contrato.

📷 **Evidencia 2:** Remix con el contrato en *Deployed Contracts* + página del contrato en sepolia.etherscan.io.

## 3. Preparar las jugadas (cada jugador, por separado)

Generar el secreto en la consola del navegador (F12 → Console):

```js
crypto.getRandomValues(new Uint32Array(4)).join('')
```

Devuelve un número de ~40 dígitos. Anotar **jugada + secreto** en un lugar seguro: sin ellos no se puede revelar y la partida se pierde.

En Remix, desplegar `calcularCompromiso` (botón azul, no cuesta gas):

| Campo | Valor |
|---|---|
| jugador | dirección propia (la de la cuenta que va a jugar) |
| jugada | 1 = Piedra, 2 = Papel, 3 = Tijera |
| secreto | el número generado |

Copiar el `bytes32` que devuelve: ese es el compromiso.

- Para ver un campo por parámetro, abrir la función con la flecha ▾.
- Escribir el secreto **entre comillas dobles** (`"8274…"`) para que Remix no redondee el número. Usar el mismo formato al revelar.

> El hash incluye la dirección del jugador. Si A calcula el compromiso de B con la dirección de A, B no podrá revelar.

## 4. Partida 1 · resolución normal

| Paso | Cuenta | Función | VALUE | Parámetros |
|---|---|---|---|---|
| 1 | A | `crearPartida` | 1 Finney (0,001 ETH) | compromiso de A |
| 2 | B | `unirsePartida` | 1 Finney | id = 1, compromiso de B |
| 3 | A | `revelar` | 0 | id = 1, jugada A, secreto A |
| 4 | B | `revelar` | 0 | id = 1, jugada B, secreto B |

- VALUE está en el panel Deploy & Run, bajo GAS LIMIT: escribir 1 y elegir la unidad **Finney**, o 1000000000000000 en Wei. Volver a 0 antes de revelar.
- Al cambiar de cuenta en MetaMask, conectarla a Remix si lo pide y verificar que ACCOUNT cambió.
- El id de la partida aparece en el log `PartidaCreada` de la consola de Remix; también sirve `totalPartidas`.
- La segunda revelación resuelve y paga en la misma transacción.

Verificar con `partidas(1)`: `estado` = 3 (Finalizada), `jugada1` y `jugada2` visibles.

📷 **Evidencia 3:** consola de Remix con el log `PartidaFinalizada`.
📷 **Evidencia 4:** Etherscan → transacción de la segunda revelación → pestaña **Internal Transactions** (Ether enviado al ganador) y pestaña **Logs**.

## 5. Partida 2 · un jugador no revela

Secretos **nuevos** (el contrato rechaza compromisos repetidos).

1. A crea, B se une.
2. Solo A revela.
3. Esperar a que `tiempoRestante(2)` devuelva 0 (5 minutos).
4. Cualquier cuenta llama `reclamarPorTimeout(2)` → A recibe el pozo completo.

📷 **Evidencia 5:** log `PartidaFinalizada` con motivo *Rival no revelo a tiempo*.

## 6. Partida 3 · nadie revela

1. A crea, B se une.
2. Nadie revela; esperar el plazo.
3. `reclamarPorTimeout(3)` → estado 4 (Anulada), cada uno recupera 0,001 ETH.

📷 **Evidencia 6:** log `PartidaAnulada` + dos transferencias internas.

## 7. Prueba de seguridad (sin gastar)

Intentar `revelar` con un secreto distinto o una jugada distinta a la comprometida. Remix/MetaMask avisan que la transacción fallará con *No coincide con tu compromiso*. Tomar captura y **rechazar** en MetaMask.

Otras pruebas útiles para la defensa: unirse con una apuesta distinta (*Debes igualar la apuesta*), revelar después del plazo (*Plazo de revelacion vencido*), revelar desde una tercera cuenta (*No participas en esta partida*).

📷 **Evidencia 7:** advertencia de transacción rechazada.

## 8. Verificar el código en Etherscan (recomendado)

Con el código verificado, Etherscan muestra el fuente, decodifica los eventos y permite leer el contrato desde *Read Contract*: es el respaldo directo de auditoría y trazabilidad.

- Opción A: plugin **Contract Verification** de Remix (Sourcify no requiere API key; Etherscan requiere una API key gratuita).
- Opción B: en Remix, clic derecho sobre `Cachipun.sol` → **Flatten**; en Etherscan → *Verify and Publish* → Solidity single file, misma versión de compilador y misma configuración de optimización usadas en Remix, licencia MIT.

## Registro del equipo

| Dato | Valor |
|---|---|
| Dirección del contrato | |
| Tx de despliegue | |
| Cuenta Jugador A | |
| Cuenta Jugador B | |
| Partida 1 (normal): tx revelación final | |
| Partida 2 (timeout, gana quien reveló): tx | |
| Partida 3 (anulada): tx | |

## Errores frecuentes

| Error | Solución |
|---|---|
| `TSTORE` / *transient storage* al compilar | Compilador 0.8.28+ y EVM version cancun o posterior |
| *not found @openzeppelin* | Revisar conexión y recompilar; Remix descarga la librería automáticamente |
| Desplegué en Remix VM | Cambiar a Injected Provider · MetaMask y volver a desplegar |
| *No coincide con tu compromiso* | El hash se calculó con otra dirección, otra jugada u otro secreto |
| *Compromiso ya utilizado* | Generar un secreto nuevo para cada partida |
| *Debes igualar la apuesta* | VALUE debe ser exactamente igual a la apuesta del creador (revisar la unidad) |
| *El plazo aun no vence* | Esperar a que `tiempoRestante(id)` sea 0 |
