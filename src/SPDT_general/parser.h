#pragma once
#include <fstream>
#include <iostream>
#include <map>
#include <unordered_map>
#include <vector>
#include "array.h"

using namespace std;
#define POS_LABEL 1
#define NEG_LABEL 0

class Data {
public:
	int label;
	unordered_map<int, double> values;
	double get_value(int feature_id);
	void read_a_data(ifstream* myfile);
};

class Dataset {
public:	
	int num_of_data;
	int num_pos_label;
	vector<Data> dataset;	
	ifstream myfile;

	int already_read_data;

	Dataset() {num_pos_label=0;}
	Dataset(int _num_of_data):		
		num_of_data(_num_of_data) {
		already_read_data = 0;
		num_pos_label=0;
	}

	void open_read_data(string name);

	bool streaming_read_data(int N);

	void close_read_data();

	void print_dataset();

};