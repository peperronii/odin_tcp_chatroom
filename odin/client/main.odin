package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:sys/posix"
import "base:runtime"

global_context : runtime.Context

main :: proc() {

	global_context = context
	err := run_client()
	if err != nil {
		fmt.println(err)
	}
}

run_client :: proc() -> net.Network_Error {
	message_buf: [512]u8
	name_buf: [64]u8
	server_socket := net.dial_tcp(net.IP4_Loopback, 4343) or_return
	defer net.close(server_socket)
	udp_endpoint := net.bound_endpoint(server_socket) or_return
	udp_socket := net.make_bound_udp_socket(udp_endpoint.address, udp_endpoint.port) or_return
	defer net.close(udp_socket)

	for {
		fmt.print("Enter Name (Max 64 characters): ")
		os.read(os.stdin, name_buf[:])
		net.send(server_socket, name_buf[:]) or_return
		net.recv(server_socket, message_buf[:]) or_return
		if message_buf[0] == '1' {
			fmt.println("Name OK!")
			break
		} else if message_buf[0] == '0' {
			fmt.println("Name Not OK! try again")
			name_buf = {}
		}
	}
	udp_thread : posix.pthread_t
	err := posix.pthread_create(&udp_thread, nil, listen_udp, &udp_socket)
	if err != nil {
		fmt.eprintln(err)
	}

	for {
		message_buf = {}
		os.read(os.stdin, message_buf[:])
		net.send_tcp(server_socket, message_buf[:]) or_return
	}

	return nil
}


listen_udp :: proc "c" (udp_socket: rawptr) -> rawptr {
	context = global_context
	udp_socket := (cast(^net.UDP_Socket)udp_socket)^

	message_buf : [512]u8
	for {
		message_buf = {}
		_, _, err := net.recv(udp_socket,message_buf[:])
		if err != nil {
			fmt.eprintln(err)
			break
		}

		fmt.printfln("%s", message_buf)
	}

	return nil
	
}