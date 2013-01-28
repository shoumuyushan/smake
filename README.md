smake
=====

smart distributed make tool for erlang 


test example:

environment : machine A and machine B is in a LAN, machine A is the master compile server, it keeps alive 24 hours.
Now, a user tries to compile his erl code in machine B .

machine A: erl -name compile_server@IPA -setcookie abc

machine B: erl -name user@IPB -setcookie abc -eval "smake:all([{compile_server, 'compile_server@IPA'}])"

IPA is the ip of machine A, IPB is the ip of machine B.

What happens  when you use smake:all/1,2 ???

First, it will join the cluster in which many computers in the LAN connect with each other.

Second, it will create remote_worker and local_worker ready to compile the source file.

Third , the master process in your computer will deliver compiling task to the remote_worker and the local_worker.

What changes in compile2.erl , epp2.erl, file2.erl ???

I change them to read and write the remote file.

In file2.erl, I use gen_server:call({?FILE_SERVER, node(group_leader())}, Request), 
    replace         gen_server:call({?FILE_SERVER, Request).

The implemention is very simple, and notice that I just test it in OTP_R15B, in higher otp release version ,you should
make a test.

呵呵，公司局域网里面空闲的机子还是很多的，欢迎提bug。

Email:      shoumuyushan@gmail.com
Tecent QQ:    812445367

====================================================================================
ver1.1
测试比较：
    在8核的i7机器上，开分布式12秒编译完我们的代码，不开分布式7秒编译完。
    在双核的E5300上，开分布式61秒编译完同一套代码，不开分布式76秒编译完。
    
此版本效果不明显的分析：
    1、头文件未管理好，导致，每个.erl文件都去解析了所有的头文件。
    2、文件传输未在远程节点做缓存，同一个文件不需要读取多次。
    3、compile加参数time后，发现远程编译时，在epp:parse_file等待了太久，可以考虑，把这部分放在本地节点做。
    
ver1.2准备做的工作：
    两个方向：1、epp:parse_file放在本地节点处理。难度：极小。
              2、增加远程节点的头文件缓存。难度：中等。
