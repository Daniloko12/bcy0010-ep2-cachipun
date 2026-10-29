// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Cachipun} from "../contracts/Cachipun.sol";

/// @dev Jugador que es un contrato, para probar receptores problemáticos.
contract JugadorContrato {
    Cachipun public juego;
    uint8 public modo; // 0 acepta Ether, 1 revierte, 2 consume todo el gas, 3 intenta reentrar

    constructor(Cachipun _juego) payable {
        juego = _juego;
    }

    function setModo(uint8 m) external {
        modo = m;
    }

    function crear(bytes32 c, uint256 v) external returns (uint256) {
        return juego.crearPartida{value: v}(c);
    }

    function unirse(uint256 id, bytes32 c, uint256 v) external {
        juego.unirsePartida{value: v}(id, c);
    }

    function revelar(uint256 id, Cachipun.Jugada j, uint256 s) external {
        juego.revelar(id, j, s);
    }

    function retirar() external {
        juego.retirar();
    }

    receive() external payable {
        if (modo == 1) revert("no acepto Ether");
        if (modo == 2) {
            while (true) {}
        }
        if (modo == 3) juego.reclamarPorTimeout(1); // intento de reentrada
    }
}

contract CachipunTest is Test {
    Cachipun juego;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant APUESTA = 0.01 ether;
    uint256 constant PLAZO = 300;

    Cachipun.Jugada constant PIEDRA = Cachipun.Jugada.Piedra;
    Cachipun.Jugada constant PAPEL = Cachipun.Jugada.Papel;
    Cachipun.Jugada constant TIJERA = Cachipun.Jugada.Tijera;

    function setUp() public {
        juego = new Cachipun(PLAZO);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Se calcula localmente (como lo haría un frontend) para no consumir vm.prank
    ///      con una llamada externa al evaluar argumentos.
    function _comp(address j, Cachipun.Jugada jug, uint256 s) internal view returns (bytes32) {
        return keccak256(abi.encode(address(juego), j, jug, s));
    }

    function test_CompromisoLocalIgualAlDelContrato() public view {
        assertEq(_comp(alice, PAPEL, 123), juego.calcularCompromiso(alice, PAPEL, 123));
    }

    function _partida(Cachipun.Jugada ja, uint256 sa, Cachipun.Jugada jb, uint256 sb) internal returns (uint256 id) {
        vm.prank(alice);
        id = juego.crearPartida{value: APUESTA}(_comp(alice, ja, sa));
        vm.prank(bob);
        juego.unirsePartida{value: APUESTA}(id, _comp(bob, jb, sb));
    }

    function _estado(uint256 id) internal view returns (Cachipun.Estado est) {
        (,,,,,,,, est) = juego.partidas(id);
    }

    // ------------------------------------------------------------------ juego normal

    function test_LasNueveCombinaciones() public {
        uint256 n;
        for (uint8 a = 1; a <= 3; a++) {
            for (uint8 b = 1; b <= 3; b++) {
                n++;
                Cachipun.Jugada ja = Cachipun.Jugada(a);
                Cachipun.Jugada jb = Cachipun.Jugada(b);
                uint256 id = _partida(ja, 1000 + n, jb, 2000 + n);

                uint256 antesA = alice.balance;
                uint256 antesB = bob.balance;

                vm.prank(alice);
                juego.revelar(id, ja, 1000 + n);
                vm.prank(bob);
                juego.revelar(id, jb, 2000 + n);

                uint256 r = (uint256(a) + 3 - uint256(b)) % 3;
                if (r == 0) {
                    assertEq(alice.balance, antesA + APUESTA, "empate: alice recupera");
                    assertEq(bob.balance, antesB + APUESTA, "empate: bob recupera");
                } else if (r == 1) {
                    assertEq(alice.balance, antesA + 2 * APUESTA, "gana alice");
                    assertEq(bob.balance, antesB, "bob pierde");
                } else {
                    assertEq(bob.balance, antesB + 2 * APUESTA, "gana bob");
                    assertEq(alice.balance, antesA, "alice pierde");
                }
                assertEq(uint8(_estado(id)), uint8(Cachipun.Estado.Finalizada));
            }
        }
        assertEq(address(juego).balance, 0, "el contrato no retiene Ether");
    }

    function test_ReglasExplicitas() public {
        // Papel le gana a Piedra
        uint256 id = _partida(PAPEL, 1, PIEDRA, 2);
        vm.prank(alice);
        juego.revelar(id, PAPEL, 1);
        vm.expectEmit(true, true, false, true);
        emit Cachipun.PartidaFinalizada(id, alice, 2 * APUESTA, "Gana jugador 1");
        vm.prank(bob);
        juego.revelar(id, PIEDRA, 2);

        // Piedra le gana a Tijera
        id = _partida(TIJERA, 3, PIEDRA, 4);
        vm.prank(bob);
        juego.revelar(id, PIEDRA, 4);
        vm.expectEmit(true, true, false, true);
        emit Cachipun.PartidaFinalizada(id, bob, 2 * APUESTA, "Gana jugador 2");
        vm.prank(alice);
        juego.revelar(id, TIJERA, 3);

        // Tijera le gana a Papel
        id = _partida(TIJERA, 5, PAPEL, 6);
        vm.prank(alice);
        juego.revelar(id, TIJERA, 5);
        vm.expectEmit(true, true, false, true);
        emit Cachipun.PartidaFinalizada(id, alice, 2 * APUESTA, "Gana jugador 1");
        vm.prank(bob);
        juego.revelar(id, PAPEL, 6);
    }

    function test_OrdenDeRevelacionNoImporta() public {
        uint256 id = _partida(PIEDRA, 1, TIJERA, 2);
        uint256 antes = alice.balance;
        vm.prank(bob);
        juego.revelar(id, TIJERA, 2);
        vm.prank(alice);
        juego.revelar(id, PIEDRA, 1);
        assertEq(alice.balance, antes + 2 * APUESTA);
    }

    function test_PlazoSeFijaAlUnirse() public {
        vm.prank(alice);
        uint256 id = juego.crearPartida{value: APUESTA}(_comp(alice, PIEDRA, 1));
        vm.warp(block.timestamp + 10_000); // esperar rival no consume plazo
        vm.prank(bob);
        juego.unirsePartida{value: APUESTA}(id, _comp(bob, PAPEL, 2));
        (,,,,,,, uint256 limite,) = juego.partidas(id);
        assertEq(limite, block.timestamp + PLAZO);
        assertEq(juego.tiempoRestante(id), PLAZO);
    }

    // ------------------------------------------------------------------ timeout

    function test_SoloRevelaJugador1_GanaPorTimeout() public {
        uint256 id = _partida(PIEDRA, 1, PAPEL, 2);
        vm.prank(alice);
        juego.revelar(id, PIEDRA, 1);

        vm.warp(block.timestamp + PLAZO + 1);
        uint256 antes = alice.balance;
        vm.prank(carol); // cualquiera puede ejecutar el cierre
        juego.reclamarPorTimeout(id);

        assertEq(alice.balance, antes + 2 * APUESTA);
        assertEq(uint8(_estado(id)), uint8(Cachipun.Estado.Finalizada));
    }

    function test_SoloRevelaJugador2_GanaPorTimeout() public {
        uint256 id = _partida(PIEDRA, 1, TIJERA, 2);
        vm.prank(bob);
        juego.revelar(id, TIJERA, 2); // bob habría perdido si alice revelaba

        vm.warp(block.timestamp + PLAZO + 1);
        uint256 antes = bob.balance;
        juego.reclamarPorTimeout(id);
        assertEq(bob.balance, antes + 2 * APUESTA);
    }

    function test_NadieRevela_SeAnula() public {
        uint256 id = _partida(PIEDRA, 1, PAPEL, 2);
        uint256 antesA = alice.balance;
        uint256 antesB = bob.balance;

        vm.warp(block.timestamp + PLAZO + 1);
        vm.expectEmit(true, false, false, false);
        emit Cachipun.PartidaAnulada(id);
        juego.reclamarPorTimeout(id);

        assertEq(alice.balance, antesA + APUESTA);
        assertEq(bob.balance, antesB + APUESTA);
        assertEq(uint8(_estado(id)), uint8(Cachipun.Estado.Anulada));
    }

    function test_RevertSi_TimeoutAntesDeVencer() public {
        uint256 id = _partida(PIEDRA, 1, PAPEL, 2);
        vm.warp(block.timestamp + PLAZO); // justo en el límite aún es válido revelar
        vm.expectRevert("El plazo aun no vence");
        juego.reclamarPorTimeout(id);
    }

    function test_RevertSi_RevelaFueraDePlazo() public {
        uint256 id = _partida(PIEDRA, 1, PAPEL, 2);
        vm.warp(block.timestamp + PLAZO + 1);
        vm.prank(alice);
        vm.expectRevert("Plazo de revelacion vencido");
        juego.revelar(id, PIEDRA, 1);
    }

    function test_RevelarEnElUltimoSegundo() public {
        uint256 id = _partida(PIEDRA, 1, PAPEL, 2);
        vm.warp(block.timestamp + PLAZO);
        vm.prank(alice);
        juego.revelar(id, PIEDRA, 1);
    }

    function test_RevertSi_TimeoutDosVeces() public {
        uint256 id = _partida(PIEDRA, 1, PAPEL, 2);
        vm.warp(block.timestamp + PLAZO + 1);
        juego.reclamarPorTimeout(id);
        vm.expectRevert("La partida no esta en revelacion");
        juego.reclamarPorTimeout(id);
    }

    // ------------------------------------------------------------------ validaciones de revelación

    function test_RevertSi_SecretoIncorrecto() public {
        uint256 id = _partida(PIEDRA, 1, PAPEL, 2);
        vm.prank(alice);
        vm.expectRevert("No coincide con tu compromiso");
        juego.revelar(id, PIEDRA, 999);
    }

    function test_RevertSi_CambiaLaJugada() public {
        uint256 id = _partida(PIEDRA, 1, TIJERA, 2);
        vm.prank(bob);
        juego.revelar(id, TIJERA, 2);
        // alice ve que bob jugó tijera e intenta cambiar a... da igual, su compromiso dice piedra
        vm.prank(alice);
        vm.expectRevert("No coincide con tu compromiso");
        juego.revelar(id, PAPEL, 1);
    }

    function test_RevertSi_JugadaNinguna() public {
        uint256 id = _partida(PIEDRA, 1, PAPEL, 2);
        vm.prank(alice);
        vm.expectRevert("Jugada invalida: usa 1, 2 o 3");
        juego.revelar(id, Cachipun.Jugada.Ninguna, 1);
    }

    function test_RevertSi_JugadaFueraDeRango() public {
        uint256 id = _partida(PIEDRA, 1, PAPEL, 2);
        // enum con valor 4: la decodificación ABI revierte
        vm.prank(alice);
        (bool ok,) = address(juego).call(abi.encodeWithSelector(juego.revelar.selector, id, uint256(4), uint256(1)));
        assertFalse(ok);
    }

    function test_RevertSi_RevelaAntesDeQueHayaRival() public {
        vm.prank(alice);
        uint256 id = juego.crearPartida{value: APUESTA}(_comp(alice, PIEDRA, 1));
        vm.prank(alice);
        vm.expectRevert("La partida no esta en revelacion");
        juego.revelar(id, PIEDRA, 1);
    }

    function test_RevertSi_RevelaUnTercero() public {
        uint256 id = _partida(PIEDRA, 1, PAPEL, 2);
        vm.prank(carol);
        vm.expectRevert("No participas en esta partida");
        juego.revelar(id, PIEDRA, 1);
    }

    function test_RevertSi_TerceroUsaSecretoAjeno() public {
        // aunque carol conozca jugada y secreto de alice, el hash incluye la dirección
        uint256 id = _partida(PIEDRA, 1, PAPEL, 2);
        vm.prank(carol);
        vm.expectRevert("No participas en esta partida");
        juego.revelar(id, PIEDRA, 1);
    }

    function test_RevertSi_RevelaDosVeces() public {
        uint256 id = _partida(PIEDRA, 1, PAPEL, 2);
        vm.startPrank(alice);
        juego.revelar(id, PIEDRA, 1);
        vm.expectRevert("Ya revelaste");
        juego.revelar(id, PIEDRA, 1);
        vm.stopPrank();
    }

    function test_RevertSi_RevelaTrasFinalizar() public {
        uint256 id = _partida(PIEDRA, 1, PAPEL, 2);
        vm.prank(alice);
        juego.revelar(id, PIEDRA, 1);
        vm.prank(bob);
        juego.revelar(id, PAPEL, 2);
        vm.prank(bob);
        vm.expectRevert("La partida no esta en revelacion");
        juego.revelar(id, PAPEL, 2);
    }

    // ------------------------------------------------------------------ validaciones de apuesta/compromiso

    function test_RevertSi_ApuestaCero() public {
        vm.prank(alice);
        vm.expectRevert("La apuesta debe ser mayor a 0");
        juego.crearPartida(_comp(alice, PIEDRA, 1));
    }

    function test_RevertSi_CompromisoVacio() public {
        vm.prank(alice);
        vm.expectRevert("Compromiso vacio");
        juego.crearPartida{value: APUESTA}(bytes32(0));
    }

    function test_RevertSi_ApuestaDistinta() public {
        vm.prank(alice);
        uint256 id = juego.crearPartida{value: APUESTA}(_comp(alice, PIEDRA, 1));
        vm.prank(bob);
        vm.expectRevert("Debes igualar la apuesta");
        juego.unirsePartida{value: APUESTA - 1}(id, _comp(bob, PAPEL, 2));
    }

    function test_RevertSi_JuegaContraSiMismo() public {
        vm.startPrank(alice);
        uint256 id = juego.crearPartida{value: APUESTA}(_comp(alice, PIEDRA, 1));
        vm.expectRevert("No puedes jugar contra ti mismo");
        juego.unirsePartida{value: APUESTA}(id, _comp(alice, PAPEL, 2));
        vm.stopPrank();
    }

    function test_RevertSi_PartidaLlena() public {
        uint256 id = _partida(PIEDRA, 1, PAPEL, 2);
        vm.prank(carol);
        vm.expectRevert("Partida no disponible");
        juego.unirsePartida{value: APUESTA}(id, _comp(carol, TIJERA, 3));
    }

    function test_RevertSi_PartidaInexistente() public {
        vm.prank(bob);
        vm.expectRevert("Partida no disponible");
        juego.unirsePartida{value: APUESTA}(42, _comp(bob, PAPEL, 2));
    }

    function test_RevertSi_CopiaCompromisoDelRival() public {
        bytes32 c = _comp(alice, PIEDRA, 1);
        vm.prank(alice);
        uint256 id = juego.crearPartida{value: APUESTA}(c);
        vm.prank(bob);
        vm.expectRevert("Compromiso ya utilizado");
        juego.unirsePartida{value: APUESTA}(id, c);
    }

    function test_CompromisoCopiadoNoSirveAunqueFueraNuevo() public view {
        // misma jugada y secreto, distinto jugador => hash distinto
        assertTrue(_comp(alice, PIEDRA, 1) != _comp(bob, PIEDRA, 1));
    }

    function test_RevertSi_ReutilizaCompromiso() public {
        bytes32 c = _comp(alice, PIEDRA, 1);
        vm.startPrank(alice);
        uint256 id = juego.crearPartida{value: APUESTA}(c);
        juego.cancelarPartida(id);
        vm.expectRevert("Compromiso ya utilizado");
        juego.crearPartida{value: APUESTA}(c);
        vm.stopPrank();
    }

    function test_RevertSi_EnvioDirectoDeEther() public {
        vm.prank(alice);
        (bool ok,) = address(juego).call{value: 1 ether}("");
        assertFalse(ok, "sin receive(): no se puede enviar Ether fuera del juego");
    }

    // ------------------------------------------------------------------ cancelación

    function test_CancelarSinRival() public {
        vm.prank(alice);
        uint256 id = juego.crearPartida{value: APUESTA}(_comp(alice, PIEDRA, 1));
        uint256 antes = alice.balance;
        vm.prank(alice);
        juego.cancelarPartida(id);
        assertEq(alice.balance, antes + APUESTA);
        assertEq(uint8(_estado(id)), uint8(Cachipun.Estado.Cancelada));
    }

    function test_RevertSi_CancelaOtro() public {
        vm.prank(alice);
        uint256 id = juego.crearPartida{value: APUESTA}(_comp(alice, PIEDRA, 1));
        vm.prank(bob);
        vm.expectRevert("Solo el creador puede cancelar");
        juego.cancelarPartida(id);
    }

    function test_RevertSi_CancelaConRival() public {
        uint256 id = _partida(PIEDRA, 1, PAPEL, 2);
        vm.prank(alice);
        vm.expectRevert("Solo partidas sin rival");
        juego.cancelarPartida(id);
    }

    // ------------------------------------------------------------------ constructor

    function test_RevertSi_PlazoMuyCorto() public {
        vm.expectRevert("Plazo minimo: 60 segundos");
        new Cachipun(59);
    }

    function test_RevertSi_PlazoMuyLargo() public {
        vm.expectRevert("Plazo maximo: 7 dias");
        new Cachipun(7 days + 1);
    }

    // ------------------------------------------------------------------ receptores problemáticos

    function _partidaContraContrato(uint8 modo) internal returns (JugadorContrato jc, uint256 id) {
        jc = new JugadorContrato{value: 1 ether}(juego);
        // el contrato crea la partida con Papel; bob juega Piedra => gana el contrato
        id = jc.crear(_comp(address(jc), PAPEL, 7), APUESTA);
        vm.prank(bob);
        juego.unirsePartida{value: APUESTA}(id, _comp(bob, PIEDRA, 8));
        jc.revelar(id, PAPEL, 7);
        jc.setModo(modo);
    }

    function test_ReceptorQueRevierte_PagoQuedaPendiente() public {
        (JugadorContrato jc, uint256 id) = _partidaContraContrato(1);
        vm.prank(bob);
        juego.revelar(id, PIEDRA, 8); // no revierte aunque el ganador rechace el Ether

        assertEq(uint8(_estado(id)), uint8(Cachipun.Estado.Finalizada));
        assertEq(juego.pagosPendientes(address(jc)), 2 * APUESTA);

        jc.setModo(0);
        uint256 antes = address(jc).balance;
        jc.retirar();
        assertEq(address(jc).balance, antes + 2 * APUESTA);
        assertEq(juego.pagosPendientes(address(jc)), 0);
        assertEq(address(juego).balance, 0);
    }

    function test_ReceptorQueConsumeGas_NoBloquea() public {
        (JugadorContrato jc, uint256 id) = _partidaContraContrato(2);
        vm.prank(bob);
        juego.revelar{gas: 500_000}(id, PIEDRA, 8);
        assertEq(juego.pagosPendientes(address(jc)), 2 * APUESTA);
    }

    function test_ReentradaBloqueada() public {
        // el receptor intenta volver a entrar al contrato durante el pago
        (JugadorContrato jc, uint256 id) = _partidaContraContrato(3);
        vm.prank(bob);
        juego.revelar(id, PIEDRA, 8);
        // la reentrada revierte => el pago se guarda como pendiente, nada se paga dos veces
        assertEq(juego.pagosPendientes(address(jc)), 2 * APUESTA);
        assertEq(address(juego).balance, 2 * APUESTA);
    }

    function test_RevertSi_RetiraSinSaldo() public {
        vm.prank(alice);
        vm.expectRevert("No tienes pagos pendientes");
        juego.retirar();
    }

    function test_EmpateConReceptorQueRevierte() public {
        JugadorContrato jc = new JugadorContrato{value: 1 ether}(juego);
        uint256 id = jc.crear(_comp(address(jc), PIEDRA, 7), APUESTA);
        vm.prank(bob);
        juego.unirsePartida{value: APUESTA}(id, _comp(bob, PIEDRA, 8));
        jc.revelar(id, PIEDRA, 7);
        jc.setModo(1);

        uint256 antesB = bob.balance;
        vm.prank(bob);
        juego.revelar(id, PIEDRA, 8);
        assertEq(bob.balance, antesB + APUESTA, "bob cobra igual");
        assertEq(juego.pagosPendientes(address(jc)), APUESTA);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_ConservacionDelEther(uint8 a, uint8 b, uint256 sa, uint256 sb, uint96 monto) public {
        a = uint8(bound(a, 1, 3));
        b = uint8(bound(b, 1, 3));
        vm.assume(monto > 0 && monto <= 5 ether);

        Cachipun.Jugada ja = Cachipun.Jugada(a);
        Cachipun.Jugada jb = Cachipun.Jugada(b);

        vm.prank(alice);
        uint256 id = juego.crearPartida{value: monto}(_comp(alice, ja, sa));
        vm.prank(bob);
        juego.unirsePartida{value: monto}(id, _comp(bob, jb, sb));

        uint256 total = alice.balance + bob.balance;
        vm.prank(alice);
        juego.revelar(id, ja, sa);
        vm.prank(bob);
        juego.revelar(id, jb, sb);

        assertEq(alice.balance + bob.balance, total + 2 * uint256(monto), "todo el pozo vuelve a los jugadores");
        assertEq(address(juego).balance, 0);
    }
}
