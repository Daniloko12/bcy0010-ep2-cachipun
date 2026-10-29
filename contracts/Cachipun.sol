// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/**
 * @title  Cachipun (piedra, papel o tijera) con apuestas en Ether
 * @notice BCY0010 Fundamentos de Blockchain · Evaluación Parcial 2
 *
 * Flujo (esquema commit-reveal):
 *   1. Jugador 1 llama crearPartida(compromiso) enviando su apuesta.
 *   2. Jugador 2 llama unirsePartida(id, compromiso) enviando la MISMA apuesta.
 *      Desde ese momento corre el plazo de revelación.
 *   3. Cada jugador llama revelar(id, jugada, secreto) dentro del plazo.
 *      Cuando ambos revelan, el contrato resuelve y paga automáticamente.
 *   4. Si vence el plazo, cualquiera llama reclamarPorTimeout(id):
 *        - solo uno reveló  -> ese jugador gana el pozo completo
 *        - nadie reveló     -> partida anulada, se devuelve cada apuesta
 *
 * compromiso = keccak256(abi.encode(direcciónContrato, jugador, jugada, secreto))
 * Se calcula con calcularCompromiso(). Incluir la dirección del jugador impide
 * copiar el compromiso del rival; incluir la dirección del contrato impide
 * reutilizarlo en otro despliegue.
 */
contract Cachipun is ReentrancyGuardTransient {
    // ---------------------------------------------------------------------
    // Tipos
    // ---------------------------------------------------------------------

    /// @dev En Remix se ingresan como número: 1 = Piedra, 2 = Papel, 3 = Tijera.
    enum Jugada {
        Ninguna, // 0: aún no revelada
        Piedra,  // 1
        Papel,   // 2
        Tijera   // 3
    }

    enum Estado {
        Inexistente,    // 0: id no usado
        EsperandoRival, // 1: jugador 1 apostó, falta jugador 2
        Revelacion,     // 2: ambos apostaron, corre el plazo para revelar
        Finalizada,     // 3: hubo ganador o empate y se pagó
        Anulada,        // 4: nadie reveló, se devolvieron las apuestas
        Cancelada       // 5: jugador 1 retiró la partida antes de que alguien se uniera
    }

    struct Partida {
        address jugador1;
        address jugador2;
        uint256 apuesta;          // monto que aporta CADA jugador, en wei
        bytes32 compromiso1;
        bytes32 compromiso2;
        Jugada jugada1;
        Jugada jugada2;
        uint256 limiteRevelacion; // timestamp (segundos) hasta el que se puede revelar
        Estado estado;
    }

    // ---------------------------------------------------------------------
    // Estado
    // ---------------------------------------------------------------------

    /// @notice Segundos que tienen los jugadores para revelar, fijado al desplegar.
    uint256 public immutable plazoRevelacion;

    /// @notice Cantidad de partidas creadas. Los id parten en 1.
    uint256 public totalPartidas;

    mapping(uint256 => Partida) public partidas;

    /// @notice Un compromiso solo puede usarse una vez (evita copiar el del rival o reutilizar secretos).
    mapping(bytes32 => bool) public compromisoUsado;

    /// @notice Ether que no se pudo enviar automáticamente; el dueño lo retira con retirar().
    mapping(address => uint256) public pagosPendientes;

    /// @dev Gas máximo que se entrega al receptor de un pago automático.
    ///      Si el receptor es un contrato que gasta todo o revierte, el pago queda pendiente
    ///      en vez de bloquear la partida.
    uint256 private constant GAS_PAGO = 50_000;

    // ---------------------------------------------------------------------
    // Eventos (trazabilidad: Etherscan los muestra en la pestaña Logs)
    // ---------------------------------------------------------------------

    event PartidaCreada(uint256 indexed id, address indexed jugador1, uint256 apuesta, bytes32 compromiso);
    event JugadorUnido(uint256 indexed id, address indexed jugador2, bytes32 compromiso, uint256 limiteRevelacion);
    event JugadaRevelada(uint256 indexed id, address indexed jugador, Jugada jugada);
    event PartidaFinalizada(uint256 indexed id, address indexed ganador, uint256 premio, string motivo);
    event PartidaAnulada(uint256 indexed id);
    event PartidaCancelada(uint256 indexed id);
    event PagoEnviado(address indexed destino, uint256 monto);
    event PagoPendiente(address indexed destino, uint256 monto);
    event Retiro(address indexed destino, uint256 monto);

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @param _plazoRevelacion segundos para revelar. Para la demo en clase: 300 (5 min).
    constructor(uint256 _plazoRevelacion) {
        require(_plazoRevelacion >= 60, "Plazo minimo: 60 segundos");
        require(_plazoRevelacion <= 7 days, "Plazo maximo: 7 dias");
        plazoRevelacion = _plazoRevelacion;
    }

    // ---------------------------------------------------------------------
    // Fase 1: compromiso + apuesta
    // ---------------------------------------------------------------------

    /// @notice Crea una partida. msg.value es la apuesta que el rival deberá igualar.
    function crearPartida(bytes32 compromiso) external payable nonReentrant returns (uint256 id) {
        require(msg.value > 0, "La apuesta debe ser mayor a 0");
        _registrarCompromiso(compromiso);

        id = ++totalPartidas;
        Partida storage p = partidas[id];
        p.jugador1 = msg.sender;
        p.apuesta = msg.value;
        p.compromiso1 = compromiso;
        p.estado = Estado.EsperandoRival;

        emit PartidaCreada(id, msg.sender, msg.value, compromiso);
    }

    /// @notice Se une a una partida abierta igualando la apuesta. Inicia el plazo de revelación.
    function unirsePartida(uint256 id, bytes32 compromiso) external payable nonReentrant {
        Partida storage p = partidas[id];
        require(p.estado == Estado.EsperandoRival, "Partida no disponible");
        require(msg.sender != p.jugador1, "No puedes jugar contra ti mismo");
        require(msg.value == p.apuesta, "Debes igualar la apuesta");
        _registrarCompromiso(compromiso);

        p.jugador2 = msg.sender;
        p.compromiso2 = compromiso;
        p.limiteRevelacion = block.timestamp + plazoRevelacion;
        p.estado = Estado.Revelacion;

        emit JugadorUnido(id, msg.sender, compromiso, p.limiteRevelacion);
    }

    /// @notice El creador recupera su apuesta si nadie se ha unido todavía.
    function cancelarPartida(uint256 id) external nonReentrant {
        Partida storage p = partidas[id];
        require(p.estado == Estado.EsperandoRival, "Solo partidas sin rival");
        require(msg.sender == p.jugador1, "Solo el creador puede cancelar");

        p.estado = Estado.Cancelada; // efecto antes de la interacción
        emit PartidaCancelada(id);
        _pagar(p.jugador1, p.apuesta);
    }

    // ---------------------------------------------------------------------
    // Fase 2: revelación
    // ---------------------------------------------------------------------

    /// @notice Revela la jugada. Debe coincidir con el compromiso enviado antes.
    /// @param jugada 1 = Piedra, 2 = Papel, 3 = Tijera
    /// @param secreto el mismo número usado al calcular el compromiso
    function revelar(uint256 id, Jugada jugada, uint256 secreto) external nonReentrant {
        Partida storage p = partidas[id];
        require(p.estado == Estado.Revelacion, "La partida no esta en revelacion");
        require(block.timestamp <= p.limiteRevelacion, "Plazo de revelacion vencido");
        require(jugada != Jugada.Ninguna, "Jugada invalida: usa 1, 2 o 3");

        bytes32 hash = calcularCompromiso(msg.sender, jugada, secreto);

        if (msg.sender == p.jugador1) {
            require(p.jugada1 == Jugada.Ninguna, "Ya revelaste");
            require(hash == p.compromiso1, "No coincide con tu compromiso");
            p.jugada1 = jugada;
        } else if (msg.sender == p.jugador2) {
            require(p.jugada2 == Jugada.Ninguna, "Ya revelaste");
            require(hash == p.compromiso2, "No coincide con tu compromiso");
            p.jugada2 = jugada;
        } else {
            revert("No participas en esta partida");
        }

        emit JugadaRevelada(id, msg.sender, jugada);

        // Resolución automática apenas ambos revelan
        if (p.jugada1 != Jugada.Ninguna && p.jugada2 != Jugada.Ninguna) {
            _resolver(id, p);
        }
    }

    /// @notice Cierra una partida cuyo plazo venció. Puede llamarla cualquiera;
    ///         el destino del Ether lo decide el contrato, no quien llama.
    function reclamarPorTimeout(uint256 id) external nonReentrant {
        Partida storage p = partidas[id];
        require(p.estado == Estado.Revelacion, "La partida no esta en revelacion");
        require(block.timestamp > p.limiteRevelacion, "El plazo aun no vence");

        bool revelo1 = p.jugada1 != Jugada.Ninguna;
        bool revelo2 = p.jugada2 != Jugada.Ninguna;
        uint256 pozo = p.apuesta * 2;

        if (revelo1 && !revelo2) {
            p.estado = Estado.Finalizada;
            emit PartidaFinalizada(id, p.jugador1, pozo, "Rival no revelo a tiempo");
            _pagar(p.jugador1, pozo);
        } else if (revelo2 && !revelo1) {
            p.estado = Estado.Finalizada;
            emit PartidaFinalizada(id, p.jugador2, pozo, "Rival no revelo a tiempo");
            _pagar(p.jugador2, pozo);
        } else {
            // Ninguno reveló (el caso "ambos revelaron" ya se resolvió en revelar)
            p.estado = Estado.Anulada;
            emit PartidaAnulada(id);
            _pagar(p.jugador1, p.apuesta);
            _pagar(p.jugador2, p.apuesta);
        }
    }

    /// @notice Retira Ether que no se pudo enviar automáticamente (patrón pull).
    function retirar() external nonReentrant {
        uint256 monto = pagosPendientes[msg.sender];
        require(monto > 0, "No tienes pagos pendientes");
        pagosPendientes[msg.sender] = 0; // efecto antes de la interacción
        emit Retiro(msg.sender, monto);
        (bool ok, ) = payable(msg.sender).call{value: monto}("");
        require(ok, "Fallo el retiro");
    }

    // ---------------------------------------------------------------------
    // Consultas
    // ---------------------------------------------------------------------

    /// @notice Calcula el compromiso que debe enviar `jugador`.
    /// @dev Es una consulta gratuita (no crea transacción), pero el secreto viaja al nodo RPC.
    ///      En producción el hash se calcula en el navegador del jugador.
    function calcularCompromiso(address jugador, Jugada jugada, uint256 secreto) public view returns (bytes32) {
        return keccak256(abi.encode(address(this), jugador, jugada, secreto));
    }

    /// @notice Segundos que quedan para revelar (0 si venció o no está en revelación).
    function tiempoRestante(uint256 id) external view returns (uint256) {
        Partida storage p = partidas[id];
        if (p.estado != Estado.Revelacion || block.timestamp >= p.limiteRevelacion) return 0;
        return p.limiteRevelacion - block.timestamp;
    }

    // ---------------------------------------------------------------------
    // Internas
    // ---------------------------------------------------------------------

    function _registrarCompromiso(bytes32 compromiso) private {
        require(compromiso != bytes32(0), "Compromiso vacio");
        require(!compromisoUsado[compromiso], "Compromiso ya utilizado");
        compromisoUsado[compromiso] = true;
    }

    /// @dev Regla: (a - b) mod 3 con Piedra=1, Papel=2, Tijera=3
    ///      0 -> empate, 1 -> gana jugador 1, 2 -> gana jugador 2
    function _resolver(uint256 id, Partida storage p) private {
        p.estado = Estado.Finalizada; // efecto antes de cualquier pago

        uint256 a = uint256(p.jugada1);
        uint256 b = uint256(p.jugada2);
        uint256 resultado = (a + 3 - b) % 3;
        uint256 pozo = p.apuesta * 2;

        if (resultado == 0) {
            emit PartidaFinalizada(id, address(0), 0, "Empate: se devuelve cada apuesta");
            _pagar(p.jugador1, p.apuesta);
            _pagar(p.jugador2, p.apuesta);
        } else if (resultado == 1) {
            emit PartidaFinalizada(id, p.jugador1, pozo, "Gana jugador 1");
            _pagar(p.jugador1, pozo);
        } else {
            emit PartidaFinalizada(id, p.jugador2, pozo, "Gana jugador 2");
            _pagar(p.jugador2, pozo);
        }
    }

    /// @dev Envío automático (push). Si falla, el monto queda en pagosPendientes (pull),
    ///      así un receptor malicioso no puede bloquear la partida.
    function _pagar(address destino, uint256 monto) private {
        (bool ok, ) = payable(destino).call{value: monto, gas: GAS_PAGO}("");
        if (ok) {
            emit PagoEnviado(destino, monto);
        } else {
            pagosPendientes[destino] += monto;
            emit PagoPendiente(destino, monto);
        }
    }
}
